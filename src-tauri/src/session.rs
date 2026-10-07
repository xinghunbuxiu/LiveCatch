//! Douyin session via in-app WebView login → local cookie store → verify / export.
//! Cookies are captured from the user's own login (no CAPTCHA bypass).
//! Exported Cookie header can be fed to open-source danmaku clients (e.g. DouyinLiveWebFetcher / douyinLive).

use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Mutex,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{
    AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent,
};
use tauri::webview::{Cookie, PageLoadEvent};
use url::Url;

pub const AUTH_LABEL: &str = "auth-login";
pub const BIND_LABEL: &str = "auth-bind";
pub const CHAT_LABEL: &str = "auth-chat";
/// Hidden WebView that stays inside the live room while watching (enter on bind, leave on stop).
pub const ROOM_LABEL: &str = "auth-room";
/// Douyin SSO QR page (aid=6383). NOT login.douyin.com — that defaults to 头条 branding.
/// service=live so webcast Cookie binds after scan.
const LOGIN_URL: &str =
    "https://sso.douyin.com/?service=https%3A%2F%2Flive.douyin.com%2F&aid=6383&language=zh&need_logo=false";
const SITE_URL: &str = "https://live.douyin.com/";
static LOGIN_WATCHING: AtomicBool = AtomicBool::new(false);
/// 扫码已确认（title 可能被跳转页覆盖，用此闩锁记住）
static LOGIN_CONFIRMED: AtomicBool = AtomicBool::new(false);
/// 正在执行关窗落盘，防止 watch / on_page_load 双触发
static LOGIN_FINISHING: AtomicBool = AtomicBool::new(false);
/// 原生主动关登录窗（扫码成功），区别于用户点关闭
static LOGIN_CLOSING: AtomicBool = AtomicBool::new(false);
/// 打开登录窗后先清 Cookie：此阶段禁止「落首页=登录成功」与注入扫码脚本
static LOGIN_PURGING: AtomicBool = AtomicBool::new(false);
/// 正在进房的 web_rid（防 session-updated → bind → enter 死循环 / 多线程重入）
static ENTERING_RID: Mutex<Option<String>> = Mutex::new(None);
/// 已绑定的房间（WebView 可能已停到 about:blank，不能再靠 URL 判断）
static BOUND_ROOM_RID: Mutex<Option<String>> = Mutex::new(None);
/// SSO 登出（清服务端会话，避免仅删本地 Cookie 后仍静默自动登录）
const LOGOUT_URL: &str =
    "https://sso.douyin.com/passport/web/logout/?aid=6383&next=https%3A%2F%2Fsso.douyin.com%2F%3Faid%3D6383";
/// web_rid → (内部 room_id, status)，避免每次发送都解析
static ROOM_ID_CACHE: Mutex<Option<(String, String, i64)>> = Mutex::new(None);
/// 复用连接，降低 TLS 握手开销
static HTTP_CLIENT: Mutex<Option<reqwest::blocking::Client>> = Mutex::new(None);
/// In-app WebView SSO: H5 confirms → navigates with lc_done → native saves once.
const INTERESTING: &[&str] = &[
    "sessionid",
    "sessionid_ss",
    "sid_guard",
    "sid_tt",
    "uid_tt",
    "uid_tt_ss",
    "ttwid",
    "passport_csrf_token",
    "passport_csrf_token_default",
    "odin_tt",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CookieEntry {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionFile {
    pub platform: String,
    pub saved_at_ms: u128,
    pub login_url: String,
    pub cookie_header: String,
    pub cookies: Vec<CookieEntry>,
    /// True only after /webcast/user/me returns status_code=0 (can send chat).
    #[serde(default)]
    pub live_ok: bool,
    /// Logged-in Douyin account (from webcast /user/me).
    #[serde(default)]
    pub account_nickname: String,
    #[serde(default)]
    pub account_uid: String,
    #[serde(default)]
    pub account_display_id: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionStatus {
    pub logged_in_hint: bool,
    pub has_sessionid: bool,
    pub has_ttwid: bool,
    pub cookie_count: usize,
    pub saved_at_ms: Option<u128>,
    pub path: Option<String>,
    pub message: String,
    /// Webcast me API accepted these cookies (needed for 公屏).
    pub live_ok: bool,
    pub account_nickname: String,
    pub account_uid: String,
    pub account_display_id: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct VerifyResult {
    pub ok: bool,
    pub http_status: u16,
    pub has_sessionid: bool,
    pub has_ttwid: bool,
    pub message: String,
    pub export_dir: Option<String>,
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// 流程日志：终端 + 推给前端（便于看卡在哪一步）
fn flow(app: &AppHandle, step: &str, status: &str, detail: impl AsRef<str>) {
    let detail = detail.as_ref();
    eprintln!("[FLOW {step}] {status} | {detail}");
    let _ = app.emit(
        "login-flow",
        serde_json::json!({
            "step": step,
            "status": status,
            "detail": detail,
            "ts": now_ms(),
        }),
    );
}

fn run_on_main<T, F>(app: &AppHandle, f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = tx.send(f());
    })
    .map_err(|e| format!("main thread: {e}"))?;
    rx.recv_timeout(Duration::from_secs(8))
        .map_err(|_| "main thread timed out".into())
}

fn collect_cookies_main(app: &AppHandle, win: &WebviewWindow) -> Vec<CookieEntry> {
    let w = win.clone();
    run_on_main(app, move || collect_cookies(&w)).unwrap_or_default()
}

fn session_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("app_data_dir: {e}"))?
        .join("session");
    fs::create_dir_all(&dir).map_err(|e| format!("mkdir session: {e}"))?;
    Ok(dir)
}

fn session_json_path(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(session_dir(app)?.join("douyin.json"))
}

fn is_douyin_domain(domain: &str) -> bool {
    let d = domain.trim_start_matches('.').to_ascii_lowercase();
    d == "douyin.com" || d.ends_with(".douyin.com") || d == "live.douyin.com"
}

fn cookie_header_from(entries: &[CookieEntry]) -> String {
    let mut map = BTreeMap::new();
    for c in entries {
        map.insert(c.name.clone(), c.value.clone());
    }
    map.into_iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

fn interesting_present(header: &str) -> (bool, bool) {
    let has_session = INTERESTING
        .iter()
        .filter(|n| n.starts_with("session") || n.starts_with("sid_") || n.starts_with("uid_"))
        .any(|n| header.contains(&format!("{n}=")));
    let has_ttwid = header.contains("ttwid=");
    (
        has_session
            || header.contains("sessionid=")
            || header.contains("sid_tt=")
            || header.contains("sid_guard="),
        has_ttwid,
    )
}

pub fn load_session(app: &AppHandle) -> Option<SessionFile> {
    let path = session_json_path(app).ok()?;
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Probe：优先信任最近一次 WebView 内授权结果；外部 HTTP 仅作补充（常因 ticket 绑定失败）。
pub fn me_api_ok(cookie_header: &str) -> bool {
    fetch_account_info(cookie_header).ok
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct WebAuthProbe {
    #[serde(default)]
    auth_ok: bool,
    #[serde(default)]
    me_ok: bool,
    #[serde(default)]
    nickname: String,
    #[serde(default)]
    uid: String,
    #[serde(default)]
    display_id: String,
    #[serde(default)]
    auth_hint: String,
    #[serde(default)]
    me_code: i64,
}

impl WebAuthProbe {
    fn ok(&self) -> bool {
        self.me_ok
    }
}

/// 在 WebView Cookie jar 内做「授权 → 账号」（credentials:include）。
/// 外部 HTTP 带导出 Cookie 常被判过期，必须以 WebView 为准。
const WEBVIEW_AUTH_PROBE_JS: &str = r###"
(async function () {
  try {
    document.title = 'LCAUTH:pending';
    var auth = null, me = null, authHint = '', authOk = false;
    try {
      auth = await fetch('https://www.douyin.com/passport/account/info/v2/?account_sdk_source=web&aid=6383', {
        credentials: 'include',
        headers: { 'Accept': 'application/json' }
      }).then(function (r) { return r.json(); });
      var ad = (auth && auth.data) || {};
      var uid = String(ad.user_id_str || ad.user_id || '');
      if (uid === '0') uid = '';
      authOk = !!(auth && auth.message === 'success' && uid);
      authHint = String(ad.description || auth.message || '');
    } catch (e1) {
      authHint = 'passport:' + String(e1);
    }
    try {
      me = await fetch('https://live.douyin.com/webcast/user/me/?aid=6383&app_name=douyin_web&device_platform=web', {
        credentials: 'include',
        headers: { 'Accept': 'application/json' }
      }).then(function (r) { return r.json(); });
    } catch (e2) {
      document.title = 'LCAUTH:' + JSON.stringify({
        auth_ok: authOk, me_ok: false, nickname: '', uid: '', display_id: '',
        auth_hint: authHint || String(e2), me_code: -1
      });
      return;
    }
    var md = (me && me.data) || {};
    var ad2 = (auth && auth.data) || {};
    var payload = {
      auth_ok: authOk,
      me_ok: !!(me && Number(me.status_code) === 0),
      nickname: String(md.nickname || md.nick_name || ad2.name || ad2.screen_name || ''),
      uid: String(md.id_str || md.id || ad2.user_id_str || ad2.user_id || ''),
      display_id: String(md.display_id || md.unique_id || ''),
      auth_hint: authHint,
      me_code: me ? Number(me.status_code) : -1
    };
    if (payload.uid === '0') payload.uid = '';
    document.title = 'LCAUTH:' + JSON.stringify(payload);
  } catch (e) {
    document.title = 'LCAUTH:' + JSON.stringify({
      auth_ok: false, me_ok: false, nickname: '', uid: '', display_id: '',
      auth_hint: String(e), me_code: -1
    });
  }
})();
"###;

fn parse_web_auth_title(title: &str) -> Option<WebAuthProbe> {
    let t = title.trim();
    let raw = t.strip_prefix("LCAUTH:")?;
    if raw == "pending" || raw.is_empty() {
        return None;
    }
    serde_json::from_str(raw).ok()
}

fn probe_auth_in_webview(win: &WebviewWindow, timeout_ms: u64) -> Option<WebAuthProbe> {
    let _ = win.eval("try{document.title='LCAUTH:pending';}catch(e){}");
    let _ = win.eval(WEBVIEW_AUTH_PROBE_JS);
    let steps = (timeout_ms / 250).max(1);
    for _ in 0..steps {
        thread::sleep(Duration::from_millis(250));
        if let Ok(title) = win.title() {
            if let Some(p) = parse_web_auth_title(&title) {
                return Some(p);
            }
            if title.starts_with("LCAUTH:") && !title.contains("pending") {
                // malformed once — stop
                break;
            }
        }
    }
    None
}

fn clear_douyin_cookies(win: &WebviewWindow) {
    // 全量删除 jar（再按域名拉一遍），避免漏删 HttpOnly / 分区 Cookie
    let mut batch: Vec<Cookie<'static>> = Vec::new();
    if let Ok(all) = win.cookies() {
        batch.extend(all);
    }
    for u in [
        "https://www.douyin.com/",
        "https://live.douyin.com/",
        "https://sso.douyin.com/",
        "https://passport.douyin.com/",
        "https://www.iesdouyin.com/",
        "https://login.douyin.com/",
    ] {
        if let Ok(url) = u.parse::<Url>() {
            if let Ok(cs) = win.cookies_for_url(url) {
                batch.extend(cs);
            }
        }
    }
    for c in batch {
        let _ = win.delete_cookie(c);
    }
    // delete 在 WKWebView 上偶发失效：再写空 Cookie 覆盖关键登录名
    const KILL: &[&str] = &[
        "sessionid",
        "sessionid_ss",
        "sid_tt",
        "sid_guard",
        "uid_tt",
        "uid_tt_ss",
        "sid_ucp_v1",
        "session_tlb_tag",
        "passport_csrf_token",
        "passport_csrf_token_default",
    ];
    const DOMAINS: &[&str] = &[
        ".douyin.com",
        "www.douyin.com",
        ".www.douyin.com",
        "live.douyin.com",
        ".live.douyin.com",
        "sso.douyin.com",
        ".sso.douyin.com",
        "passport.douyin.com",
        ".passport.douyin.com",
    ];
    for name in KILL {
        for domain in DOMAINS {
            let mut blank = Cookie::new(*name, "");
            blank.set_domain(*domain);
            blank.set_path("/");
            let _ = win.set_cookie(blank);
            let mut del = Cookie::new(*name, "");
            del.set_domain(*domain);
            del.set_path("/");
            let _ = win.delete_cookie(del);
        }
    }
    let _ = win.eval(
        r###"(function(){
  try {
    var parts = document.cookie.split(';');
    for (var i = 0; i < parts.length; i++) {
      var n = (parts[i].split('=')[0] || '').trim();
      if (!n) continue;
      var domains = ['', '.douyin.com', 'douyin.com', 'sso.douyin.com', '.sso.douyin.com',
        'live.douyin.com', '.live.douyin.com', 'www.douyin.com', '.www.douyin.com',
        'passport.douyin.com', '.passport.douyin.com'];
      for (var j = 0; j < domains.length; j++) {
        var d = domains[j];
        document.cookie = d
          ? (n + '=; path=/; domain=' + d + '; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT')
          : (n + '=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT');
      }
    }
    try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}
  } catch (e) {}
})()"###,
    );
}

/// WKWebView / WebView2 的 Cookie API 必须在主线程调用，否则经常删不掉。
fn clear_douyin_cookies_main(app: &AppHandle, win: &WebviewWindow) {
    let w = win.clone();
    let _ = run_on_main(app, move || clear_douyin_cookies(&w));
}

fn jar_has_session_main(app: &AppHandle, win: &WebviewWindow) -> bool {
    let w = win.clone();
    run_on_main(app, move || jar_has_session(&w)).unwrap_or(false)
}

fn session_cookie_names_main(app: &AppHandle, win: &WebviewWindow) -> String {
    let w = win.clone();
    run_on_main(app, move || {
        w.cookies()
            .unwrap_or_default()
            .into_iter()
            .filter(|c| {
                let n = c.name().to_ascii_lowercase();
                n.contains("session") || n.starts_with("sid_") || n.starts_with("uid_")
            })
            .map(|c| c.name().to_string())
            .collect::<Vec<_>>()
            .join(",")
    })
    .unwrap_or_default()
}

fn login_url_bust() -> String {
    format!("{LOGIN_URL}&_lc={}", now_ms())
}

/// jar 里是否还残留登录态 Cookie
fn jar_has_session(win: &WebviewWindow) -> bool {
    let Ok(all) = win.cookies() else {
        return false;
    };
    all.iter().any(|c| {
        let n = c.name().to_ascii_lowercase();
        n == "sessionid"
            || n == "sessionid_ss"
            || n == "sid_tt"
            || n == "sid_guard"
            || n == "uid_tt"
            || n == "uid_tt_ss"
            || n == "sid_ucp_v1"
    })
}

/// 退出登录 / 扫码前：关房间窗并清 WebView Cookie jar（同步等到清理结束）
fn purge_webview_session(app: &AppHandle) {
    leave_room(app);
    for label in [AUTH_LABEL, "auth-me", "auth-purge"] {
        if let Some(w) = app.get_webview_window(label) {
            clear_douyin_cookies(&w);
            let _ = w.close();
        }
    }
    // 临时打开抖音域页面才能删掉 HttpOnly / 跨站 Cookie
    let Ok(url) = "https://www.douyin.com/".parse::<Url>() else {
        return;
    };
    let Ok(win) = WebviewWindowBuilder::new(app, "auth-purge", WebviewUrl::External(url))
        .title("LiveCatch · 清理会话")
        .inner_size(320.0, 200.0)
        .visible(false)
        .user_agent(CHROME_UA)
        .build()
    else {
        return;
    };
    let app2 = app.clone();
    let win2 = win.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(400));
        clear_douyin_cookies(&win2);
        if let Ok(u) = LOGOUT_URL.parse::<Url>() {
            let _ = win2.navigate(u);
        }
        thread::sleep(Duration::from_millis(800));
        clear_douyin_cookies(&win2);
        if let Ok(u) = LOGIN_URL.parse::<Url>() {
            let _ = win2.navigate(u);
        }
        thread::sleep(Duration::from_millis(500));
        clear_douyin_cookies(&win2);
        if let Ok(u) = "https://live.douyin.com/".parse::<Url>() {
            let _ = win2.navigate(u);
        }
        thread::sleep(Duration::from_millis(400));
        clear_douyin_cookies(&win2);
        let _ = win2.close();
        flow(&app2, "SESSION_CLEAR", "ok", "WebView Cookie 已清理");
        let _ = tx.send(());
    });
    // 最多等 5s，避免退出命令永远卡住；超时也继续删本地文件
    let _ = rx.recv_timeout(Duration::from_secs(5));
}

#[derive(Debug, Clone, Default)]
struct AuthInfo {
    /// passport 会话是否有效（授权信息）
    ok: bool,
    user_id: String,
    session_key: String,
    hint: String,
}

#[derive(Debug, Clone, Default)]
struct AccountInfo {
    ok: bool,
    nickname: String,
    uid: String,
    display_id: String,
    status_code: i64,
    raw_hint: String,
}

/// Backward-compatible alias used by older call sites.
type MeProfile = AccountInfo;

fn http_client() -> Option<reqwest::blocking::Client> {
    let mut guard = HTTP_CLIENT.lock().ok()?;
    if let Some(c) = guard.as_ref() {
        return Some(c.clone());
    }
    let c = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(8))
        .connect_timeout(Duration::from_secs(3))
        .pool_max_idle_per_host(4)
        .redirect(reqwest::redirect::Policy::limited(5))
        .user_agent(CHROME_UA)
        .gzip(true)
        .brotli(true)
        .deflate(true)
        .build()
        .ok()?;
    *guard = Some(c.clone());
    Some(c)
}

fn cache_room_id(web_rid: &str, room_id: &str, st: i64) {
    if web_rid.is_empty() || room_id.is_empty() {
        return;
    }
    if let Ok(mut g) = ROOM_ID_CACHE.lock() {
        *g = Some((web_rid.to_string(), room_id.to_string(), st));
    }
}

fn cached_room_id(web_rid: &str) -> Option<(String, i64)> {
    let g = ROOM_ID_CACHE.lock().ok()?;
    let (rid, id, st) = g.as_ref()?;
    if rid == web_rid && !id.is_empty() {
        Some((id.clone(), *st))
    } else {
        None
    }
}

fn read_json_response(resp: reqwest::blocking::Response, api: &str) -> Result<serde_json::Value, String> {
    let status = resp.status().as_u16();
    let ctype = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    let text = resp.text().unwrap_or_default();
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(format!("{api} 空响应 (HTTP {status})，登录态可能失效，请重新扫码"));
    }
    if trimmed.starts_with('<')
        || ctype.contains("text/html")
        || trimmed.to_ascii_lowercase().contains("<!doctype")
    {
        return Err(format!(
            "{api} 返回了网页而非 JSON（HTTP {status}）— 通常是未登录或 Cookie 失效，请重新扫码"
        ));
    }
    serde_json::from_str(trimmed).map_err(|e| {
        let preview: String = trimmed.chars().take(80).collect();
        format!("{api} 非 JSON（HTTP {status}）：{e} · {preview}")
    })
}

/// Step 1 — 授权：用 Cookie 换 passport 会话是否有效（先于账号信息）。
fn fetch_passport_auth(cookie_header: &str) -> AuthInfo {
    if cookie_header.trim().is_empty() {
        return AuthInfo {
            hint: "无 Cookie".into(),
            ..AuthInfo::default()
        };
    }
    let Some(client) = http_client() else {
        return AuthInfo {
            hint: "HTTP 客户端失败".into(),
            ..AuthInfo::default()
        };
    };
    let resp = match client
        .get("https://www.douyin.com/passport/account/info/v2/?account_sdk_source=web&aid=6383")
        .header("Cookie", cookie_header)
        .header("Referer", "https://www.douyin.com/")
        .header("Origin", "https://www.douyin.com")
        .header("Accept", "application/json")
        .send()
    {
        Ok(r) => r,
        Err(e) => {
            return AuthInfo {
                hint: format!("授权请求失败：{e}"),
                ..AuthInfo::default()
            };
        }
    };
    let body = match read_json_response(resp, "passport") {
        Ok(v) => v,
        Err(e) => {
            return AuthInfo {
                hint: e,
                ..AuthInfo::default()
            };
        }
    };
    let msg = body.get("message").and_then(|x| x.as_str()).unwrap_or("");
    let data = body.get("data").cloned().unwrap_or(serde_json::json!({}));
    let err = data.get("error_code").and_then(|x| x.as_i64()).unwrap_or(0);
    let desc = data
        .get("description")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let user_id = data
        .get("user_id_str")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            data.get("user_id")
                .and_then(|x| x.as_i64())
                .filter(|n| *n > 0)
                .map(|n| n.to_string())
        })
        .unwrap_or_default();
    let session_key = data
        .get("session_key")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let ok = (msg == "success" || err == 0)
        && !user_id.is_empty()
        && err != 13
        && !desc.contains("过期")
        && !desc.contains("重新登录");
    AuthInfo {
        ok,
        user_id,
        session_key,
        hint: if ok {
            String::new()
        } else if !desc.is_empty() {
            desc
        } else {
            format!("passport message={msg} error_code={err}")
        },
    }
}

/// Step 2 — 账号信息：授权通过后再拉 webcast /user/me（昵称 / uid）。
fn fetch_account_info(cookie_header: &str) -> AccountInfo {
    if cookie_header.trim().is_empty() {
        return AccountInfo::default();
    }
    let Some(client) = http_client() else {
        return AccountInfo {
            raw_hint: "HTTP 客户端失败".into(),
            ..AccountInfo::default()
        };
    };
    let resp = match client
        .get("https://live.douyin.com/webcast/user/me/?aid=6383&app_name=douyin_web&device_platform=web")
        .header("Cookie", cookie_header)
        .header("Referer", SITE_URL)
        .header("Origin", "https://live.douyin.com")
        .header("Accept", "application/json")
        .send()
    {
        Ok(r) => r,
        Err(e) => {
            return AccountInfo {
                raw_hint: format!("me 请求失败：{e}"),
                ..AccountInfo::default()
            };
        }
    };
    let status = resp.status().as_u16();
    let body = match read_json_response(resp, "me") {
        Ok(v) => v,
        Err(e) => {
            return AccountInfo {
                status_code: -1,
                raw_hint: e,
                ..AccountInfo::default()
            };
        }
    };
    let code = body.get("status_code").and_then(|x| x.as_i64()).unwrap_or(-1);
    let data = body.get("data").cloned().unwrap_or(serde_json::json!({}));
    let nickname = data
        .get("nickname")
        .and_then(|x| x.as_str())
        .or_else(|| data.get("nick_name").and_then(|x| x.as_str()))
        .unwrap_or("")
        .to_string();
    let uid = data
        .get("id_str")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .or_else(|| data.get("id").map(|x| x.to_string()))
        .unwrap_or_default();
    let display_id = data
        .get("display_id")
        .and_then(|x| x.as_str())
        .or_else(|| data.get("unique_id").and_then(|x| x.as_str()))
        .unwrap_or("")
        .to_string();
    let ok = code == 0;
    AccountInfo {
        ok,
        nickname,
        uid,
        display_id,
        status_code: code,
        raw_hint: if ok {
            String::new()
        } else {
            format!("me status_code={code} HTTP {status}")
        },
    }
}

/// 授权 → 账号：先 passport，再 webcast me。返回 (auth_ok, account)。
fn authorize_then_account(cookie_header: &str) -> (AuthInfo, AccountInfo) {
    let auth = fetch_passport_auth(cookie_header);
    if !auth.ok {
        return (auth, AccountInfo {
            raw_hint: "授权未通过，跳过账号拉取".into(),
            ..AccountInfo::default()
        });
    }
    let mut acct = fetch_account_info(cookie_header);
    // passport 有 uid 时补齐空 uid
    if acct.uid.is_empty() && !auth.user_id.is_empty() {
        acct.uid = auth.user_id.clone();
    }
    (auth, acct)
}

/// Old name kept for call sites.
fn fetch_me_profile(cookie_header: &str) -> Option<MeProfile> {
    let (auth, acct) = authorize_then_account(cookie_header);
    if !auth.ok && !acct.ok {
        return Some(AccountInfo {
            ok: false,
            status_code: acct.status_code,
            raw_hint: if auth.hint.is_empty() {
                acct.raw_hint
            } else {
                auth.hint
            },
            ..AccountInfo::default()
        });
    }
    Some(acct)
}

pub fn session_status(app: &AppHandle) -> SessionStatus {
    match load_session(app) {
        None => SessionStatus {
            logged_in_hint: false,
            has_sessionid: false,
            has_ttwid: false,
            cookie_count: 0,
            saved_at_ms: None,
            path: session_json_path(app).ok().map(|p| p.display().to_string()),
            message: "尚未授权。请「扫码登录」；进房只需 Cookie。".into(),
            live_ok: false,
            account_nickname: String::new(),
            account_uid: String::new(),
            account_display_id: String::new(),
        },
        Some(s) => {
            let (has_sessionid, has_ttwid) = interesting_present(&s.cookie_header);
            // 不在这里打外部 HTTP / 阻塞 WebView：live_ok 与昵称由扫码窗或进房时 WebView 探测写入
            let live_ok = s.live_ok && has_sessionid;
            let logged_in_hint = has_sessionid;
            let who = if !s.account_nickname.is_empty() {
                format!("「{}」", s.account_nickname)
            } else if !s.account_display_id.is_empty() {
                format!("「{}」", s.account_display_id)
            } else {
                String::new()
            };
            SessionStatus {
                logged_in_hint,
                has_sessionid,
                has_ttwid,
                cookie_count: s.cookies.len(),
                saved_at_ms: Some(s.saved_at_ms),
                path: session_json_path(app).ok().map(|p| p.display().to_string()),
                live_ok,
                account_nickname: s.account_nickname.clone(),
                account_uid: s.account_uid.clone(),
                account_display_id: s.account_display_id.clone(),
                message: if live_ok && !who.is_empty() {
                    format!("已授权 {who}，可发公屏")
                } else if live_ok {
                    "已授权，可发公屏".into()
                } else if has_sessionid {
                    "Cookie 已保存，可进房。请重新扫码完成 WebView 内授权以显示账号/发公屏".into()
                } else if has_ttwid {
                    "已有 ttwid，但缺少 sessionid——请重新扫码。".into()
                } else {
                    "Cookie 不完整，请重新扫码授权。".into()
                },
            }
        }
    }
}



#[cfg(target_os = "macos")]
const CHROME_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";
#[cfg(windows)]
const CHROME_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0";
#[cfg(not(any(target_os = "macos", windows)))]
const CHROME_UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

static FINISH_ONCE: AtomicBool = AtomicBool::new(false);

/// 页面加载完成后再次注入（Windows WebView2 上 about:blank→外链时 init script 可能未生效）
fn login_init_script() -> &'static str {
    #[cfg(windows)]
    {
        OPEN_LOGIN_SCRIPT_WIN
    }
    #[cfg(not(windows))]
    {
        OPEN_LOGIN_SCRIPT
    }
}

fn inject_open_login_script(win: &WebviewWindow) {
    let script = login_init_script();
    let Ok(js) = serde_json::to_string(script) else {
        return;
    };
    let _ = win.eval(&format!(
        "try{{delete window.__lcOpenLogin;}}catch(e){{}};try{{eval({js});}}catch(e){{console.error('[lc-login]',e);}}"
    ));
}

/// Windows：不盖遮罩，直接显示抖音 SSO 原生扫码页（WebView2 上自定义壳易空白）
const OPEN_LOGIN_SCRIPT_WIN: &str = r#"
(function () {
  if (window.__lcOpenLogin) return;
  window.__lcOpenLogin = 1;
  function setTitle(s) { try { document.title = s; } catch (e) {} }
  // 打开扫码页时清掉上次残留确认标，避免未扫码就 LCLOGIN:ok
  try { document.cookie = 'lc_qr_confirmed=; path=/; domain=.douyin.com; max-age=0'; } catch (e) {}
  function handle(url, text) {
    if (!text || !url || !/check_qrconnect/i.test(String(url))) return;
    try {
      var j = JSON.parse(text);
      var d = (j && j.data) || {};
      var st = String(d.status || '');
      if (st === '3') {
        try { document.cookie = 'lc_qr_confirmed=1; path=/; domain=.douyin.com; max-age=600'; } catch (e) {}
        setTitle('LCLOGIN:ok');
      }
    } catch (e) {}
  }
  function urlOf(input) {
    try {
      if (typeof input === 'string') return input;
      if (input && typeof input.url === 'string') return input.url;
    } catch (e) {}
    return '';
  }
  try {
    var _fetch = window.fetch;
    if (typeof _fetch === 'function') {
      window.fetch = function (input, init) {
        var url = urlOf(input);
        return _fetch.apply(this, arguments).then(function (resp) {
          if (!/check_qrconnect/i.test(url)) return resp;
          return resp.clone().text().then(function (t) {
            handle(url, t);
            return resp;
          }).catch(function () { return resp; });
        });
      };
    }
  } catch (e) {}
  try {
    var _open = XMLHttpRequest.prototype.open;
    var _send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__lcUrl = url || '';
      return _open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      xhr.addEventListener('load', function () {
        try { handle(xhr.__lcUrl || '', xhr.responseText); } catch (e) {}
      });
      return _send.apply(this, arguments);
    };
  } catch (e) {}
  try { localStorage.removeItem('HasUserLogin'); } catch (e) {}
})();
"#;

/// 扫码页：出码 + 监听 check_qrconnect；确认后 title=LCLOGIN:ok，原生轮询关窗。
const OPEN_LOGIN_SCRIPT: &str = r#"
(function () {
  if (window.__lcOpenLogin && document.getElementById('lc-login-shell')) return;
  window.__lcOpenLogin = 1;

  function setTitle(s) { try { document.title = s; } catch (e) {} }
  function publish(kind, data) {
    try { window.postMessage({ __lc: kind, data: data }, '*'); } catch (e) {}
  }
  function handle(url, text) {
    if (!text || !url || !/get_qrcode|check_qrconnect/i.test(String(url))) return;
    try {
      var j = JSON.parse(text);
      var d = (j && j.data) || {};
      if (/get_qrcode/i.test(String(url))) publish('qr', d);
      if (/check_qrconnect/i.test(String(url))) publish('check', d);
    } catch (e) {}
  }
  /** 确认后剥掉 redirect_url，避免站点自己跳到 www 发现页 */
  function stripRedirect(text) {
    try {
      var j = JSON.parse(text);
      if (j && j.data && String(j.data.status) === '3' && j.data.redirect_url) {
        delete j.data.redirect_url;
        return JSON.stringify(j);
      }
    } catch (e) {}
    return null;
  }
  function urlOf(input) {
    try {
      if (typeof input === 'string') return input;
      if (input && typeof input.url === 'string') return input.url;
    } catch (e) {}
    return '';
  }
  try {
    var _fetch = window.fetch;
    if (typeof _fetch === 'function') {
      window.fetch = function (input, init) {
        var url = urlOf(input);
        return _fetch.apply(this, arguments).then(function (resp) {
          if (!/get_qrcode|check_qrconnect/i.test(url)) return resp;
          return resp.clone().text().then(function (t) {
            handle(url, t);
            if (/check_qrconnect/i.test(url)) {
              var stripped = stripRedirect(t);
              if (stripped) {
                return new Response(stripped, {
                  status: resp.status,
                  statusText: resp.statusText,
                  headers: resp.headers
                });
              }
            }
            return resp;
          }).catch(function () { return resp; });
        });
      };
    }
  } catch (e) {}
  try {
    var _open = XMLHttpRequest.prototype.open;
    var _send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__lcUrl = url || '';
      return _open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {|| {
                let _ = w.close();
            }
        });
        if let Some(p) = probe {
            if p.ok() || !p.nickname.is_empty() || !p.uid.is_empty() {
                match persist_cookies_with_account(
                    &app2,
                    cookies,
                    p.me_ok,
                    &p.nickname,
                    &p.uid,
                    &p.display_id,
                ) {
                    Ok(st) => {
                        let _ = app2.emit("session-updated", &st);
                        flow(
                            &app2,
                            "STEP4_ME",
                            "ok",
                            format!(
                                "WebView 昵称={} uid={} me_ok={}",
                                st.account_nickname, st.account_uid, p.me_ok
                            ),
                        );
                        return;
                    }
                    Err(e) => flow(&app2, "STEP4_ME", "fail", format!("WebView 写盘失败: {e}")),
                }
            } else {
                flow(
                    &app2,
                    "STEP4_ME",
                    "warn",
                    format!("WebView 探测无账号 hint={}", p.auth_hint),
                );
            }
        } else {
            flow(&app2, "STEP4_ME", "warn", "WebView 探测超时，进房时再试");
        }
    });
}

/// STEP2→3：主线程读 Cookie → 落盘 → 关窗；成功后再 STEP4。
fn finish_login_session(app: &AppHandle, win: &WebviewWindow) -> bool {
    if LOGIN_PURGING.load(Ordering::SeqCst) {
        return false;
    }
    // 必须已扫码确认，禁止仅凭 jar 里残留 sessionid 落盘
    if !LOGIN_CONFIRMED.load(Ordering::SeqCst) {
        return false;
    }
    if LOGIN_FINISHING.swap(true, Ordering::SeqCst) {
        return true;
    }
    flow(app, "STEP2_SESSION", "check", "主线程读取 Cookie / sessionid");
    let w = win.clone();
    let cookies = match run_on_main(app, move || collect_cookies(&w)) {
        Ok(c) => c,
        Err(e) => {
            flow(app, "STEP2_SESSION", "fail", format!("读 Cookie 失败: {e}"));
            LOGIN_FINISHING.store(false, Ordering::SeqCst);
            return false;
        }
    };
    let header = cookie_header_from(&cookies);
    let (has_sid, has_ttwid) = interesting_present(&header);
    let names: Vec<_> = cookies.iter().map(|c| c.name.as_str()).collect();
    flow(
        app,
        "STEP2_SESSION",
        if has_sid { "ok" } else { "wait" },
        format!(
            "sid={has_sid} ttwid={has_ttwid} n={} names={names:?}",
            cookies.len()
        ),
    );
    if !has_sid {
        LOGIN_FINISHING.store(false, Ordering::SeqCst);
        return false;
    }
    // 退出登录可能在读 Cookie 后插入：写盘前再拦一次
    if LOGIN_PURGING.load(Ordering::SeqCst) || !LOGIN_CONFIRMED.load(Ordering::SeqCst) {
        LOGIN_FINISHING.store(false, Ordering::SeqCst);
        return false;
    }

    flow(app, "STEP3_CLOSE", "start", "session 已满足，落盘并关闭登录窗");
    let persist = persist_cookies_with_account(app, cookies, false, "", "", "");
    match persist {
        Ok(st) => {
            let _ = app.emit("session-updated", &st);
            LOGIN_CLOSING.store(true, Ordering::SeqCst);
            LOGIN_WATCHING.store(false, Ordering::SeqCst);
            let wclose = win.clone();
            let closed = run_on_main(app, move || {
                let _ = wclose.eval(
                    "try{var el=document.getElementById('lc-qr-status');if(el)el.textContent='登录成功';}catch(e){}",
                );
                // close 可能只发请求；destroy 强制卸掉，避免「扫码成功窗还在」
                let _ = wclose.close();
                let _ = wclose.destroy();
            });
            match closed {
                Ok(()) => flow(app, "STEP3_CLOSE", "ok", "登录窗已关闭"),
                Err(e) => flow(app, "STEP3_CLOSE", "warn", format!("主线程关窗: {e}")),
            }
            if let Some(w) = app.get_webview_window(AUTH_LABEL) {
                let _ = run_on_main(app, move || {
                    let _ = w.destroy();
                });
            }
            LOGIN_CONFIRMED.store(false, Ordering::SeqCst);
            LOGIN_FINISHING.store(false, Ordering::SeqCst);
            LOGIN_CLOSING.store(false, Ordering::SeqCst);
            FINISH_ONCE.store(false, Ordering::SeqCst);
            refresh_me_after_login(app);
            true
        }
        Err(e) => {
            flow(app, "STEP3_CLOSE", "fail", format!("落盘失败: {e}"));
            LOGIN_FINISHING.store(false, Ordering::SeqCst);
            false
        }
    }
}

fn stop_login_watch(reason: &str) {
    LOGIN_WATCHING.store(false, Ordering::SeqCst);
    LOGIN_CONFIRMED.store(false, Ordering::SeqCst);
    LOGIN_FINISHING.store(false, Ordering::SeqCst);
    LOGIN_PURGING.store(false, Ordering::SeqCst);
    LOGIN_CLOSING.store(false, Ordering::SeqCst);
    FINISH_ONCE.store(false, Ordering::SeqCst);
    let _ = reason;
}

fn auth_login_alive(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(AUTH_LABEL)
}

/// 轮询 STEP2：等 sessionid / 首页落地 → finish。
/// 用户随时可关登录窗：关窗后立刻停轮询，禁止再碰已销毁的 WebView（否则 Tauri RecvError 崩进程）。
fn watch_login_until_done(app: &AppHandle, _win: &WebviewWindow) {
    if FINISH_ONCE.swap(true, Ordering::SeqCst) {
        return;
    }
    LOGIN_CONFIRMED.store(false, Ordering::SeqCst);
    let app = app.clone();
    thread::spawn(move || {
        flow(&app, "STEP2_SESSION", "start", "开始轮询扫码结果 / sessionid");
        thread::sleep(Duration::from_millis(800));
        if let Some(w) = auth_login_alive(&app) {
            let _ = run_on_main(&app, move || {
                let _ = w.eval(
                    "try{document.cookie='lc_qr_confirmed=; path=/; domain=.douyin.com; max-age=0';if(document.title==='LCLOGIN:ok')document.title='LiveCatch';}catch(e){}",
                );
            });
        }
        LOGIN_CONFIRMED.store(false, Ordering::SeqCst);
        let mut confirmed_ticks: u32 = 0;
        for i in 0..180 {
            if !LOGIN_WATCHING.load(Ordering::SeqCst) {
                if LOGIN_CLOSING.load(Ordering::SeqCst) {
                    return;
                }
                flow(&app, "STEP2_SESSION", "abort", "用户已关闭或取消登录");
                stop_login_watch("watching=false");
                return;
            }
            let Some(win) = auth_login_alive(&app) else {
                if LOGIN_CLOSING.load(Ordering::SeqCst) {
                    return;
                }
                flow(&app, "STEP2_SESSION", "abort", "登录窗已关闭");
                stop_login_watch("window-gone");
                return;
            };
            if LOGIN_PURGING.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(200));
                continue;
            }

            let title_ok = win
                .title()
                .ok()
                .map(|t| t.contains("LCLOGIN:ok"))
                .unwrap_or(false);
            let confirmed_cookie = {
                let w = win.clone();
                run_on_main(&app, move || {
                    if !LOGIN_WATCHING.load(Ordering::SeqCst) {
                        return false;
                    }
                    raw_qr_confirmed(&w)
                })
                .unwrap_or(false)
            };
            if title_ok || confirmed_cookie {
                LOGIN_CONFIRMED.store(true, Ordering::SeqCst);
            }
            let confirmed = LOGIN_CONFIRMED.load(Ordering::SeqCst);
            if confirmed {
                confirmed_ticks = confirmed_ticks.saturating_add(1);
            }

            if !LOGIN_WATCHING.load(Ordering::SeqCst) || auth_login_alive(&app).is_none() {
                if LOGIN_CLOSING.load(Ordering::SeqCst) {
                    return;
                }
                flow(&app, "STEP2_SESSION", "abort", "登录窗已关闭");
                stop_login_watch("closed-mid-loop");
                return;
            }
            let url_now = win.url().map(|u| u.to_string()).unwrap_or_default();
            let on_qr_host = url_now.contains("sso.douyin.com")
                || url_now.contains("passport.douyin.com")
                || url_now.contains("/login_page");
            // 未确认前偶尔补注入；确认后绝不再 inject（会冲掉成功态）
            if !confirmed && on_qr_host && i % 8 == 0 {
                if auth_login_alive(&app).is_some() && LOGIN_WATCHING.load(Ordering::SeqCst) {
                    inject_open_login_script(&win);
                }
            }

            if !LOGIN_WATCHING.load(Ordering::SeqCst) || auth_login_alive(&app).is_none() {
                if LOGIN_CLOSING.load(Ordering::SeqCst) {
                    return;
                }
                flow(&app, "STEP2_SESSION", "abort", "登录窗已关闭");
                stop_login_watch("closed-before-cookies");
                return;
            }
            let cookies = collect_cookies_main(&app, &win);
            let header = cookie_header_from(&cookies);
            let (has_sid, _) = interesting_present(&header);
            let landed_home = url_now.contains("live.douyin.com")
                || (url_now.contains("www.douyin.com") && !url_now.contains("login"));

            // incognito 仓初始无会话：一旦出现 sessionid，就是刚扫码成功
            if has_sid {
                LOGIN_CONFIRMED.store(true, Ordering::SeqCst);
            }
            let confirmed = LOGIN_CONFIRMED.load(Ordering::SeqCst);

            if has_sid {
                flow(
                    &app,
                    "STEP2_SESSION",
                    "ok",
                    format!("拿到 sessionid，落盘关窗（landed={landed_home}）"),
                );
                if let Some(w) = auth_login_alive(&app) {
                    if finish_login_session(&app, &w) {
                        return;
                    }
                } else if LOGIN_CLOSING.load(Ordering::SeqCst) {
                    return;
                }
            } else if confirmed && confirmed_ticks % 5 == 0 {
                flow(
                    &app,
                    "STEP2_SESSION",
                    "wait",
                    format!("已确认扫码，等待 sessionid… ticks={confirmed_ticks}"),
                );
            }
            if i % 8 == 0 {
                flow(
                    &app,
                    "STEP2_SESSION",
                    "wait",
                    format!(
                        "i={i} sid={has_sid} confirmed={confirmed} title_ok={title_ok} cookies={} url={url_now}",
                        cookies.len()
                    ),
                );
            }
            thread::sleep(Duration::from_millis(if confirmed { 250 } else { 400 }));
        }
        flow(&app, "STEP2_SESSION", "fail", "等待超时");
        if let Some(w) = auth_login_alive(&app) {
            let _ = w.eval(
                "var el=document.getElementById('lc-qr-status'); if(el) el.textContent='等待超时，请关闭后重试';",
            );
        }
        stop_login_watch("timeout");
    });
}

pub fn open_login(app: &AppHandle) -> Result<(), String> {
    if std::env::var("LIVECATCH_LOGIN_PLAYWRIGHT").ok().as_deref() == Some("1") {
        return open_login_playwright(app);
    }

    flow(app, "STEP1_OPEN", "start", "打开扫码登录窗（incognito）");
    // incognito 仓无需 purge；PURGING=false，避免首屏注入被拦住
    LOGIN_PURGING.store(false, Ordering::SeqCst);
    LOGIN_WATCHING.store(false, Ordering::SeqCst);
    LOGIN_CONFIRMED.store(false, Ordering::SeqCst);
    LOGIN_FINISHING.store(false, Ordering::SeqCst);
    LOGIN_CLOSING.store(false, Ordering::SeqCst);
    FINISH_ONCE.store(false, Ordering::SeqCst);
    if let Some(w) = app.get_webview_window(AUTH_LABEL) {
        clear_douyin_cookies_main(app, &w);
        let _ = w.close();
    }
    if let Some(w) = app.get_webview_window("auth-purge") {
        let _ = w.close();
    }
    // 先关房间窗并清 jar，避免「退出后扫码仍自动登录」
    leave_room(app);
    // 等旧窗真正卸掉，避免 "label already exists"
    for _ in 0..20 {
        if app.get_webview_window(AUTH_LABEL).is_none() {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    if app.get_webview_window(AUTH_LABEL).is_some() {
        LOGIN_PURGING.store(false, Ordering::SeqCst);
        return Err("登录窗仍在关闭中，请稍后重试".into());
    }

    // 登录窗用 incognito / 非持久 DataStore：与默认 jar 隔离，天然无旧 session。
    // 再跟默认仓死磕 delete_cookie 没用（WKWebView 共享 jar 删不干净）。
    let login_start: Url = login_url_bust()
        .parse()
        .map_err(|e| format!("url: {e}"))?;
    let app_for_load = app.clone();
    let app_err = app.clone();
    let mut login_builder = WebviewWindowBuilder::new(
        app,
        AUTH_LABEL,
        WebviewUrl::External(login_start),
    )
        .title("LiveCatch · 扫码登录")
        .inner_size(440.0, 640.0)
        .resizable(false)
        .center()
        .user_agent(CHROME_UA)
        .incognito(true)
        .initialization_script(login_init_script())
        .initialization_script_for_all_frames(login_init_script());
    #[cfg(windows)]
    {
        // 关闭自动化特征 + 允许混合内容，减少 SSO 白屏
        login_builder = login_builder.additional_browser_args(
            "--disable-blink-features=AutomationControlled --disable-features=msSmartScreenProtection",
        );
    }
    let win = login_builder
        .on_page_load(move |w, payload| {
            if LOGIN_PURGING.load(Ordering::SeqCst) {
                return;
            }
            if payload.event() == PageLoadEvent::Finished {
                let url = payload.url().to_string();
                // SSO / passport / 官方 login_page 都注入扫码壳；真正的首页不注入
                let inject = url.contains("sso.douyin.com")
                    || url.contains("passport.douyin.com")
                    || url.contains("/login_page")
                    || url.contains("login.douyin.com");
                if inject {
                    inject_open_login_script(&w);
                }
            }
            if !LOGIN_WATCHING.load(Ordering::SeqCst) {
                return;
            }
            if payload.event() != PageLoadEvent::Finished {
                return;
            }
            let url = payload.url().to_string();
            let url_l = url.to_ascii_lowercase();
            if url_l.contains("login")
                || url_l.contains("logout")
                || url_l.contains("sso.douyin.com")
                || url_l.contains("passport.douyin.com")
            {
                return;
            }
            let landed = url.contains("www.douyin.com")
                || url.contains("live.douyin.com")
                || url.contains("iesdouyin.com");
            if !landed {
                return;
            }
            flow(
                &app_for_load,
                "STEP2_SESSION",
                "landed",
                format!("页面落到: {url}"),
            );
            // incognito：落到 live/www 后由后台采 cookie；有 sessionid 即可落盘
            let app3 = app_for_load.clone();
            let w3 = w.clone();
            thread::spawn(move || {
                for _ in 0..30 {
                    if LOGIN_PURGING.load(Ordering::SeqCst) || !LOGIN_WATCHING.load(Ordering::SeqCst)
                    {
                        return;
                    }
                    let cookies = collect_cookies_main(&app3, &w3);
                    let header = cookie_header_from(&cookies);
                    let (has_sid, _) = interesting_present(&header);
                    if has_sid {
                        LOGIN_CONFIRMED.store(true, Ordering::SeqCst);
                        if finish_login_session(&app3, &w3) {
                            return;
                        }
                    }
                    thread::sleep(Duration::from_millis(300));
                }
            });
        })
        .build()
        .map_err(|e| {
            stop_login_watch("build-fail");
            flow(&app_err, "STEP1_OPEN", "fail", format!("{e}"));
            format!("打开登录窗失败：{e}")
        })?;

    // 用户关登录窗：立刻停轮询，禁止后台线程再调已销毁 WebView（RecvError 根因）
    let app_close = app_err.clone();
    win.on_window_event(move |ev| {
        match ev {
            WindowEvent::CloseRequested { .. } | WindowEvent::Destroyed => {
                if LOGIN_CLOSING.load(Ordering::SeqCst) {
                    // 扫码成功后的主动关窗，不要当成「用户取消」
                    LOGIN_WATCHING.store(false, Ordering::SeqCst);
                    return;
                }
                if LOGIN_WATCHING.load(Ordering::SeqCst) || FINISH_ONCE.load(Ordering::SeqCst) {
                    flow(
                        &app_close,
                        "STEP1_OPEN",
                        "abort",
                        "用户关闭登录窗（未登录也可关）",
                    );
                }
                stop_login_watch("user-close");
            }
            _ => {}
        }
    });

    flow(
        &app_err,
        "STEP1_OPEN",
        "ok",
        "登录窗已创建（incognito；可随时关闭，不会崩）",
    );
    let app2 = app_err.clone();
    let win2 = win.clone();
    thread::spawn(move || {
        LOGIN_CONFIRMED.store(false, Ordering::SeqCst);
        LOGIN_PURGING.store(false, Ordering::SeqCst);
        LOGIN_WATCHING.store(true, Ordering::SeqCst);
        thread::sleep(Duration::from_millis(500));
        if !LOGIN_WATCHING.load(Ordering::SeqCst) || auth_login_alive(&app2).is_none() {
            flow(&app2, "STEP1_OPEN", "abort", "登录窗已关闭");
            stop_login_watch("closed-before-inject");
            return;
        }
        inject_open_login_script(&win2);
        thread::sleep(Duration::from_millis(500));
        if !LOGIN_WATCHING.load(Ordering::SeqCst) || auth_login_alive(&app2).is_none() {
            flow(&app2, "STEP1_OPEN", "abort", "登录窗已关闭");
            stop_login_watch("closed-before-watch");
            return;
        }
        inject_open_login_script(&win2);
        let cur = run_on_main(&app2, {
            let w = win2.clone();
            move || {
                if !LOGIN_WATCHING.load(Ordering::SeqCst) {
                    return String::new();
                }
                w.url().map(|u| u.to_string()).unwrap_or_default()
            }
        })
        .unwrap_or_default();
        if !LOGIN_WATCHING.load(Ordering::SeqCst) || auth_login_alive(&app2).is_none() {
            flow(&app2, "STEP1_OPEN", "abort", "登录窗已关闭");
            stop_login_watch("closed-before-watch2");
            return;
        }
        let on_qr = cur.contains("sso.douyin.com")
            || cur.contains("passport.douyin.com")
            || cur.contains("/login_page");
        if on_qr {
            flow(
                &app2,
                "STEP1_OPEN",
                "ok",
                format!("已在扫码页 sid={}", jar_has_session_main(&app2, &win2)),
            );
        } else if !cur.is_empty() {
            flow(
                &app2,
                "STEP1_OPEN",
                "warn",
                format!("未停在扫码页（{cur}），再导航一次"),
            );
            if let Some(w) = auth_login_alive(&app2) {
                let target = login_url_bust();
                let _ = run_on_main(&app2, move || {
                    if let Ok(u) = target.parse::<Url>() {
                        let _ = w.navigate(u);
                    }
                });
                thread::sleep(Duration::from_millis(600));
                if let Some(w2) = auth_login_alive(&app2) {
                    inject_open_login_script(&w2);
                }
            }
        }
        if !LOGIN_WATCHING.load(Ordering::SeqCst) || auth_login_alive(&app2).is_none() {
            flow(&app2, "STEP1_OPEN", "abort", "登录窗已关闭");
            stop_login_watch("closed-before-watch3");
            return;
        }
        watch_login_until_done(&app2, &win2);
    });
    Ok(())
}

fn resolve_login_qr_script(app: &AppHandle) -> Result<PathBuf, String> {
    let mut cands = Vec::new();
    if let Ok(d) = app.path().resource_dir() {
        cands.push(d.join("tools/plugins/q1-douyin/login_qr.py"));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(p) = exe.parent() {
            cands.push(p.join("tools/plugins/q1-douyin/login_qr.py"));
            #[cfg(target_os = "macos")]
            {
                cands.push(p.join("../Resources/tools/plugins/q1-douyin/login_qr.py"));
            }
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        cands.push(cwd.join("tools/plugins/q1-douyin/login_qr.py"));
        cands.push(cwd.join("src-tauri/tools/plugins/q1-douyin/login_qr.py"));
    }
    cands.push(PathBuf::from("tools/plugins/q1-douyin/login_qr.py"));
    for p in cands {
        if p.is_file() {
            return Ok(p);
        }
    }
    Err("找不到 login_qr.py".into())
}

fn open_login_playwright(app: &AppHandle) -> Result<(), String> {
    let script = resolve_login_qr_script(app)?;
    let session = session_dir(app)?;
    if let Some(w) = app.get_webview_window(AUTH_LABEL) {
        let _ = w.close();
    }
    let dir = session_dir(app)?;
    let path = dir.join("login_wait.html");
    fs::write(
        &path,
        "<!doctype html><meta charset=utf-8><title>LiveCatch</title><body style=\"margin:0;background:#0b0b0c;color:#f2f2f2;font:14px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh\"><div style=\"text-align:center\"><h1>LiveCatch</h1><p id=st>正在打开扫码窗口…</p></div>",
    )
    .map_err(|e| e.to_string())?;
    let html_url = Url::from_file_path(&path).map_err(|_| "bad file url".to_string())?;
    let win = WebviewWindowBuilder::new(app, AUTH_LABEL, WebviewUrl::External(html_url))
        .title("LiveCatch · 扫码登录")
        .inner_size(400.0, 260.0)
        .resizable(false)
        .center()
        .build()
        .map_err(|e| format!("打开登录提示窗失败：{e}"))?;

    if LOGIN_WATCHING.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let app2 = app.clone();
    let win2 = win.clone();
    thread::spawn(move || {
        use std::io::{BufRead, BufReader};
        use std::process::{Command, Stdio};
        let mut child = match Command::new("python3")
            .arg(&script)
            .env("LIVECATCH_SESSION_DIR", &session)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                let _ = win2.eval(&format!(
                    "document.getElementById('st').textContent={}",
                    serde_json::to_string(&format!("启动失败：{e}")).unwrap_or_default()
                ));
                LOGIN_WATCHING.store(false, Ordering::SeqCst);
                return;
            }
        };
        if let Some(out) = child.stdout.take() {
            for line in BufReader::new(out).lines().flatten() {
                let line = line.trim().to_string();
                if line.is_empty() {
                    continue;
                }
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) {
                    let msg = v
                        .get("message")
                        .and_then(|x| x.as_str())
                        .or_else(|| v.get("status").and_then(|x| x.as_str()))
                        .unwrap_or("…");
                    let _ = win2.eval(&format!(
                        "var el=document.getElementById('st'); if(el) el.textContent={};",
                        serde_json::to_string(msg).unwrap_or_default()
                    ));
                    if v.get("status").and_then(|x| x.as_str()) == Some("ok") {
                        let st = session_status(&app2);
                        let _ = app2.emit("session-updated", &st);
                        let _ = win2.close();
                        let _ = child.wait();
                        LOGIN_WATCHING.store(false, Ordering::SeqCst);
                        return;
                    }
                }
            }
        }
        let _ = child.wait();
        LOGIN_WATCHING.store(false, Ordering::SeqCst);
    });
    Ok(())
}


fn collect_cookies(win: &WebviewWindow) -> Vec<CookieEntry> {
    let mut seen = BTreeMap::<String, CookieEntry>::new();
    let mut ingest = |list: Vec<Cookie<'static>>| {
        for c in list {
            let domain = c.domain().unwrap_or("").to_string();
            let name = c.name().to_string();
            let value = c.value().to_string();
            if name.is_empty() || value.is_empty() || name.starts_with("lc_") {
                continue;
            }
            if !domain.is_empty() && !is_douyin_domain(&domain) {
                continue;
            }
            seen.insert(
                name.clone(),
                CookieEntry {
                    name,
                    value,
                    domain: if domain.is_empty() {
                        ".douyin.com".into()
                    } else {
                        domain
                    },
                    path: c.path().unwrap_or("/").to_string(),
                },
            );
        }
    };
    if let Ok(all) = win.cookies() {
        ingest(all);
    }
    // WKWebView 有时 cookies() 不全，按域名再拉一遍
    for u in [
        "https://www.douyin.com/",
        "https://live.douyin.com/",
        "https://sso.douyin.com/",
        "https://www.douyin.com/passport/",
    ] {
        if let Ok(url) = u.parse::<Url>() {
            if let Ok(cs) = win.cookies_for_url(url) {
                ingest(cs);
            }
        }
    }
    seen.into_values().collect()
}

fn persist_cookies(
    app: &AppHandle,
    collected: Vec<CookieEntry>,
    live_ok: bool,
) -> Result<SessionStatus, String> {
    // 进房等场景：只落 Cookie；账号字段保留旧值，不因外部 HTTP 失败而清空
    let prev = load_session(app);
    let nick = prev
        .as_ref()
        .map(|s| s.account_nickname.clone())
        .unwrap_or_default();
    let uid = prev
        .as_ref()
        .map(|s| s.account_uid.clone())
        .unwrap_or_default();
    let did = prev
        .as_ref()
        .map(|s| s.account_display_id.clone())
        .unwrap_or_default();
    let live = live_ok
        || prev.as_ref().map(|s| s.live_ok).unwrap_or(false);
    persist_cookies_with_account(app, collected, live, &nick, &uid, &did)
}

/// 写入 Cookie +（可选）WebView 探测到的账号信息。
fn persist_cookies_with_account(
    app: &AppHandle,
    collected: Vec<CookieEntry>,
    live_ok: bool,
    nickname: &str,
    uid: &str,
    display_id: &str,
) -> Result<SessionStatus, String> {
    if collected.is_empty() {
        return Err("未读到抖音 Cookie。请在登录窗完成授权后再保存。".into());
    }
    let cleaned: Vec<CookieEntry> = collected
        .into_iter()
        .filter(|c| !c.name.starts_with("lc_"))
        .collect();
    let header = cookie_header_from(&cleaned);
    let prev = load_session(app);
    let nick = if !nickname.is_empty() {
        nickname.to_string()
    } else {
        prev.as_ref()
            .map(|s| s.account_nickname.clone())
            .unwrap_or_default()
    };
    let uid = if !uid.is_empty() {
        uid.to_string()
    } else {
        prev.as_ref()
            .map(|s| s.account_uid.clone())
            .unwrap_or_default()
    };
    let did = if !display_id.is_empty() {
        display_id.to_string()
    } else {
        prev.as_ref()
            .map(|s| s.account_display_id.clone())
            .unwrap_or_default()
    };
    let file = SessionFile {
        platform: "douyin".into(),
        saved_at_ms: now_ms(),
        login_url: LOGIN_URL.into(),
        cookie_header: header,
        cookies: cleaned,
        live_ok,
        account_nickname: nick,
        account_uid: uid,
        account_display_id: did,
    };
    let dir = session_dir(app)?;
    let json_path = dir.join("douyin.json");
    let raw = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;
    fs::write(&json_path, raw).map_err(|e| format!("写入失败：{e}"))?;
    fs::write(dir.join("cookie_header.txt"), &file.cookie_header)
        .map_err(|e| format!("写 cookie_header：{e}"))?;
    write_netscape(&dir.join("cookies.netscape.txt"), &file.cookies)?;
    write_verify_readme(&dir)?;
    Ok(session_status(app))
}

pub fn save_from_webview(app: &AppHandle) -> Result<SessionStatus, String> {
    let win = app
        .get_webview_window(AUTH_LABEL)
        .or_else(|| app.get_webview_window("main"))
        .ok_or_else(|| "没有可用窗口。请先「打开登录」。".to_string())?;
    let collected = collect_cookies(&win);
    let header = cookie_header_from(&collected);
    let (has_sid, _) = interesting_present(&header);
    let live_ok = me_api_ok(&header);
    let st = persist_cookies(app, collected, live_ok)?;
    if has_sid {
        let _ = win.close();
        let _ = app.emit("session-updated", &st);
    }
    Ok(st)
}

/// Push saved session cookies into a WebView (no QR — reuse disk Cookie).
/// Only inject cookies WebKit will accept (avoids "string did not match expected pattern").
fn inject_saved_cookies(win: &WebviewWindow, entries: &[CookieEntry]) {
    for e in entries {
        if e.name.is_empty()
            || e.name.starts_with("lc_")
            || e.name == "livecatch_bound"
            || e.name == "livecatch_chat_res"
        {
            continue;
        }
        if !e.name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '$'))
        {
            continue;
        }
        if e.value.is_empty() || e.value.len() > 4096 {
            continue;
        }
        if e.value.chars().any(|c| matches!(c, ';' | '\n' | '\r' | '\0')) {
            continue;
        }
        let mut c = Cookie::new(e.name.clone(), e.value.clone());
        let dom = if e.domain.is_empty() {
            ".douyin.com".to_string()
        } else if e.domain.starts_with('.') {
            e.domain.clone()
        } else if e.domain.contains('.') {
            format!(".{}", e.domain.trim_start_matches('.'))
        } else {
            continue;
        };
        if dom.matches('.').count() < 1 {
            continue;
        }
        c.set_domain(dom);
        c.set_path(if e.path.is_empty() {
            "/".into()
        } else {
            e.path.clone()
        });
        let _ = win.set_cookie(c);
    }
}

fn normalize_room_url(room_url: &str) -> Result<String, String> {
    let room = room_url.trim();
    if room.is_empty() {
        return Err("缺少直播间地址".into());
    }
    if room.starts_with("http://") || room.starts_with("https://") {
        Ok(room.to_string())
    } else {
        Ok(format!("https://live.douyin.com/{room}"))
    }
}

/// Close room / bind / chat helper windows (= leave the live room).
pub fn leave_room(app: &AppHandle) {
    if let Ok(mut g) = ROOM_ID_CACHE.lock() {
        *g = None;
    }
    if let Ok(mut g) = ENTERING_RID.lock() {
        *g = None;
    }
    if let Ok(mut g) = BOUND_ROOM_RID.lock() {
        *g = None;
    }
    for label in [ROOM_LABEL, BIND_LABEL, CHAT_LABEL, "auth-me"] {
        if let Some(w) = app.get_webview_window(label) {
            // 默认仓：尽量清浏览数据，避免污染后续 WebView
            let _ = w.clear_all_browsing_data();
            clear_douyin_cookies(&w);
            let _ = w.close();
        }
    }
    let _ = app.emit(
        "session-bind",
        serde_json::json!({"status":"left","message":"已离开直播间"}),
    );
}

/// Drop guard：进房结束（成功/失败/提前返回）时清掉 ENTERING_RID，允许下次进别的房。
struct EnterRoomGuard;
impl Drop for EnterRoomGuard {
    fn drop(&mut self) {
        if let Ok(mut g) = ENTERING_RID.lock() {
            *g = None;
        }
    }
}

/// 产品路径不再打开隐藏直播间 WebView。
/// 播放=FFmpeg，弹幕=直连 WSS，发公屏=HTTP + 盘上 Cookie；此处只校验 session 并预热 room_id。
pub fn enter_room(app: &AppHandle, room_url: &str) -> Result<SessionStatus, String> {
    flow(app, "STEP5_ENTER", "start", format!("绑定 url={room_url}（无 WebView）"));
    let sess = load_session(app).ok_or_else(|| {
        flow(app, "STEP5_ENTER", "fail", "无本地 session");
        "请先扫码授权（仅首次需要）".to_string()
    })?;
    let (has_sid, _) = interesting_present(&sess.cookie_header);
    if !has_sid {
        flow(app, "STEP5_ENTER", "fail", "无 sessionid");
        return Err("本地无 Cookie/sessionid，请先扫码授权".into());
    }
    let rid = room_web_rid(room_url).map_err(|e| {
        flow(app, "STEP5_ENTER", "fail", &e);
        e
    })?;

    let already_bound = BOUND_ROOM_RID
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .as_deref()
        == Some(rid.as_str());
    if already_bound {
        flow(app, "STEP5_ENTER", "skip", format!("已绑定 rid={rid}"));
        let st = session_status(app);
        let _ = app.emit(
            "session-bind",
            serde_json::json!({"status":"ok","message":format!("已绑定直播间 {rid}")}),
        );
        return Ok(st);
    }
    {
        let g = ENTERING_RID.lock().unwrap();
        if g.as_deref() == Some(rid.as_str()) {
            flow(app, "STEP5_ENTER", "skip", format!("rid={rid} 绑定中"));
            return Ok(session_status(app));
        }
    }
    {
        let mut g = ENTERING_RID.lock().unwrap();
        *g = Some(rid.clone());
    }
    let _enter_guard = EnterRoomGuard;

    // 关掉历史遗留的房间/绑定窗，避免再抢 CDN
    for label in [ROOM_LABEL, BIND_LABEL, CHAT_LABEL] {
        if let Some(w) = app.get_webview_window(label) {
            let _ = w.close();
        }
    }

    if cached_room_id(&rid).is_none() {
        if let Some(client) = http_client() {
            let _ = resolve_room_id_fast(&client, &sess.cookie_header, &rid);
        }
    }
    if let Ok(mut g) = BOUND_ROOM_RID.lock() {
        *g = Some(rid.clone());
    }
    let st = session_status(app);
    let who = if !st.account_nickname.is_empty() {
        format!(" · {}", st.account_nickname)
    } else {
        String::new()
    };
    let _ = app.emit(
        "session-bind",
        serde_json::json!({
            "status":"ok",
            "message":format!("已绑定直播间 {rid}{who}（直连/HTTP，无房间页）")
        }),
    );
    flow(
        app,
        "STEP5_ENTER",
        "ok",
        format!("已绑定 rid={rid}{who}（无 WebView）"),
    );
    Ok(st)
}

/// Bind = enter the live room (kept for callers). Prefer enter_room.
pub fn bind_session_to_room(app: &AppHandle, room_url: &str) -> Result<SessionStatus, String> {
    enter_room(app, room_url)
}

fn write_netscape(path: &PathBuf, cookies: &[CookieEntry]) -> Result<(), String> {
    let mut out = String::new();
    out.push_str("# Netscape HTTP Cookie File");
    out.push(char::from(10));
    out.push_str("# LiveCatch Desk export for open-source clients");
    out.push(char::from(10));

    for c in cookies {
        let domain = if c.domain.starts_with('.') {
            c.domain.clone()
        } else {
            format!(".{}", c.domain.trim_start_matches('.'))
        };

        out.push_str(&domain);
        out.push(char::from(9));
        out.push_str("TRUE");
        out.push(char::from(9));
        out.push_str(&c.path);
        out.push(char::from(9));
        out.push_str("FALSE");
        out.push(char::from(9));
        out.push_str("0");
        out.push(char::from(9));
        out.push_str(&c.name);
        out.push(char::from(9));
        out.push_str(&c.value);
        out.push(char::from(10));
    }

    fs::write(path, out).map_err(|e| format!("netscape: {e}"))
}

fn write_verify_readme(dir: &PathBuf) -> Result<(), String> {
    let text = concat!(
        "# Douyin session export (LiveCatch Desk)\n",
        "\n",
        "Files:\n",
        "- douyin.json            full session\n",
        "- cookie_header.txt      Cookie request header value\n",
        "- cookies.netscape.txt   Netscape cookie jar\n",
        "\n",
        "## Verify with LiveCatch\n",
        "\n",
        "Cookies are saved automatically after login.\n",
        "If no session exists before starting a stream, the QR login window is opened.\n",
        "\n",
        "## Open-source danmaku clients\n",
        "\n",
        "Use cookie_header.txt as the request Cookie value, or import\n",
        "cookies.netscape.txt when the client supports Netscape cookies.\n"
    );
    fs::write(dir.join("README.txt"), text).map_err(|e| format!("session README: {e}"))
}
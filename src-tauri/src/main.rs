#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod player;
use serde::Serialize;
use std::{collections::{HashSet, VecDeque}, env, fs, io::{BufRead, BufReader, Write}, path::PathBuf, process::{Child, ChildStdin, Command, Stdio}, sync::{atomic::{AtomicU64, Ordering}, mpsc, Arc, Mutex}, thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
use tauri::{Emitter, Manager, State};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

const QCAP: usize = 64;
const HC: usize = 100;
/// Default per-request wait (health / tiny ops).
const QTIME: Duration = Duration::from_secs(8);
/// Playwright DOM send needs Chrome launch + room load.
const QTIME_SEND: Duration = Duration::from_secs(45);
static Q1_REQUEST_SEQ: AtomicU64 = AtomicU64::new(0);

struct RuntimeState {
    room_url: Option<String>,
    last_stream_url: Option<String>,
    q1_last_ms: Option<u128>,
    q1_tx: Option<mpsc::SyncSender<Q1Job>>,
    q1_queued: usize,
    q1_queued_ids: HashSet<String>,
    q1_cancelled: HashSet<String>,
    q1_inflight: bool,
    q1_active: Option<String>,
    q1_history: VecDeque<Q1Record>,
    q1_adapter_healthy: bool,
    q1_adapter_pid: Option<u32>,
    q1_adapter_restarts: u64,
    live_tx: Option<mpsc::SyncSender<LiveJob>>,
    live_seq: u64,
    live_generation: u64,
    live_active: Option<String>,
    live_retry: u32,
    playback: Arc<Mutex<Option<player::LivePlaybackEngine>>>,
}
struct AppState(Arc<Mutex<RuntimeState>>);
struct Q1Job { id:String, payload:serde_json::Value, reply:tauri::AppHandle, client_ts_ms:u128 }
struct LiveJob { id:String, generation:u64, room_url:String, reply:tauri::AppHandle }
struct Q1Daemon { child:Child, stdin:ChildStdin, rx:mpsc::Receiver<String> }
impl Q1Daemon {
    fn kill_wait(&mut self){
        let _=self.child.kill();
        let _=self.child.wait();
    }
}
#[derive(Serialize,Clone)] struct Candidate{url:String,protocol:String,host:String,latency:u128,status:String,score:i64}
#[derive(Serialize,Clone)] struct PlaybackHealth{ipc_ok:bool,time_pos:Option<f64>,buffer_sec:Option<f64>,paused:Option<bool>,idle:Option<bool>,eof:Option<bool>,stalled:bool,buffering:bool,frame_drops:Option<u64>,decoder_frame_drops:Option<u64>,speed:Option<f64>,latency_mode:Option<String>,sample_ms:u128}
#[derive(Serialize,Clone)] struct LiveEvent{task_id:String,generation:u64,attempt:u32,phase:String,message:String,stream_url:Option<String>,protocol:Option<String>,cdn:Option<String>,health:Option<String>,latency_ms:Option<u128>,playback:Option<PlaybackHealth>,candidates:Vec<Candidate>}
#[derive(Serialize)] struct StartResult{task_id:String,status:String,message:String}
#[derive(Serialize,Clone)] struct Q1Record{request_id:String,code:String,name:String,qty:i32,status:String,message:String,queued_ms:u128,adapter_ms:u128,send_ms:u128,time:String}
#[derive(Serialize)] struct Q1Result{request_id:String,status:String,transport:String,send_ms:u128,message:String}
#[derive(Serialize)] struct Q1Status{available:bool,adapter:String,platform:String,message:String,plugin:Option<Q1PluginInfo>,queued:usize,inflight:bool,active:Option<String>,adapter_healthy:bool,adapter_pid:Option<u32>,adapter_restarts:u64,history:Vec<Q1Record>,p50_ms:u128,p95_ms:u128,p99_ms:u128}
#[derive(Serialize)] struct Q1ProductMap{code:String,product_id:i64}

fn now()->String{format!("unix:{}",SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs())}
fn now_ms()->u128{SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()}
fn detect_platform(room:&str)->String{let s=room.to_lowercase();if s.contains("douyin.com"){"douyin"}else if s.contains("bilibili.com"){"bilibili"}else if s.contains("douyu.com"){"douyu"}else if s.contains("huya.com"){"huya"}else if s.contains("kuaishou.com"){"kuaishou"}else{"unknown"}.into()}
fn exe_candidates(app:Option<&tauri::AppHandle>,n:&str)->Vec<PathBuf>{let mut v=vec![];if let Some(app)=app{if let Ok(d)=app.path().resource_dir(){
            let os=std::env::consts::OS; let arch=std::env::consts::ARCH;
            let platform=match os {"windows"=>"windows","macos"=>"macos","linux"=>"linux",x=>x};
            for base in [d.join("tools"),d.join("tools").join(platform),d.join("tools").join(format!("{}-{}",platform,arch))]{
                v.push(base.join(n));
            }
            v.push(d.join(n));
        }}if let Ok(cur)=env::current_exe(){if let Some(d)=cur.parent(){
            let os=std::env::consts::OS; let arch=std::env::consts::ARCH;
            let platform=match os {"windows"=>"windows","macos"=>"macos","linux"=>"linux",x=>x};
            for base in [d.join("tools"),d.join("tools").join(platform),d.join("tools").join(format!("{}-{}",platform,arch))]{
                v.push(base.join(n));
            }
            v.push(d.join(n));
            #[cfg(target_os="macos")]v.push(d.join("../Resources/tools").join(n));
        }}if let Ok(cwd)=env::current_dir(){v.push(cwd.join(n)); v.push(cwd.join("tools").join(n));}#[cfg(target_os="macos")]for d in ["/opt/homebrew/bin","/usr/local/bin","/opt/local/bin","/usr/bin"]{v.push(PathBuf::from(d).join(n));}v.push(PathBuf::from(n));v}
fn find_exe(app:Option<&tauri::AppHandle>,n:&str)->Result<PathBuf,String>{
    for p in exe_candidates(app,n){
        if !(p.is_absolute()&&p.exists()){
            if !p.is_absolute() && Command::new(&p).arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).output().map(|x|x.status.success()).unwrap_or(false){
                return Ok(PathBuf::from(n));
            }
            continue;
        }
        return Ok(p);
    }
    Err(format!("找不到 {n}，请放入 tools 目录"))
}
fn run_command_timeout(mut c:std::process::Command,timeout:Duration)->Result<std::process::Output,String>{
    let mut child=c.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e|e.to_string())?;
    let started=Instant::now();
    loop{
        match child.try_wait(){
            Ok(Some(_))=>return child.wait_with_output().map_err(|e|e.to_string()),
            Ok(None)=>{
                if started.elapsed()>=timeout{let _=child.kill();let _=child.wait();return Err(format!("外部解析器超时（{} ms）",timeout.as_millis()));}
                thread::sleep(Duration::from_millis(25));
            }
            Err(e)=>{let _=child.kill();let _=child.wait();return Err(e.to_string());}
        }
    }
}
fn web_rid_from_url(room:&str)->Option<String>{
    let u=url::Url::parse(room).ok()?;
    let host=u.host_str()?.to_ascii_lowercase();
    if !(host=="live.douyin.com"||host.ends_with(".live.douyin.com")){return None;}
    let seg=u.path().trim_matches('/').split('/').next().unwrap_or("");
    if seg.chars().all(|c|c.is_ascii_digit())&&!seg.is_empty(){Some(seg.into())}else{None}
}
/// Douyin room status via webcast enter: 2=living, 3/4=ended.
fn probe_room_status(app:&tauri::AppHandle,room:&str)->Option<i64>{
    let rid=web_rid_from_url(room)?;
    let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(8)).build().ok()?;
    let enter=format!(
        "https://live.douyin.com/webcast/room/web/enter/?aid=6383&app_name=douyin_web&live_id=1&device_platform=web&language=zh-CN&enter_from=web_live&cookie_enabled=true&web_rid={rid}"
    );
    let mut req=client.get(&enter)
        .header("User-Agent","Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .header("Referer","https://live.douyin.com/");
    let body:serde_json::Value=serde_json::from_str(&req.send().ok()?.text().ok()?).ok()?;
    let data=body.get("data")?;
    let rooms=data.get("data").and_then(|x|x.as_array());
    let room0=rooms.and_then(|a|a.first());
    let status=room0.and_then(|r|r.get("status")).and_then(|x|x.as_i64())
        .or_else(||data.get("room_status").and_then(|x|x.as_i64()));
    status
}
fn classify_no_stream(app:&tauri::AppHandle,room:&str)->String{
    match probe_room_status(app,room){
        Some(3)|Some(4)=>"直播已结束".into(),
        Some(2)=>"没有找到 FLV/HLS 地址".into(),
        Some(0)=>{
            // Ambiguous: scrape page text as fallback
            if let Some(rid)=web_rid_from_url(room){
                            if let Ok(client)=reqwest::blocking::Client::builder().timeout(Duration::from_secs(6)).build(){
                    let mut req=client.get(format!("https://live.douyin.com/{rid}"))
                        .header("User-Agent","Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
                                    if let Ok(resp)=req.send(){
                        if let Ok(html)=resp.text(){
                            if html.contains("直播已结束"){return "直播已结束".into();}
                            if html.contains("页面不存在")||html.contains("链接错误")||html.contains("没有找到相关内容"){
                                return format!("无效直播间：{rid}");
                            }
                        }
                    }
                }
            }
            "没有找到 FLV/HLS 地址".into()
        }
        _=>"没有找到 FLV/HLS 地址".into(),
    }
}
fn is_ended_err(e:&str)->bool{e.contains("直播已结束")||e.contains("无效直播间")}
fn resolve(app:&tauri::AppHandle,room:&str)->Result<lixh_stream_resolver::ResolvedStream,String>{
    tauri::async_runtime::block_on(lixh_stream_resolver::resolve(room, None, None))
        .map_err(|e| {
            let raw=e.to_string();
            if raw.is_empty() || raw.contains("no stream") || raw.contains("empty") || raw.contains("extract") {
                classify_no_stream(app, room)
            } else { raw }
        })
}

fn emit_live(app:&tauri::AppHandle,e:LiveEvent){let _=app.emit("live-event",e);}
fn live_current(state:&Arc<Mutex<RuntimeState>>,id:&str,generation:u64)->bool{let g=state.lock().unwrap();g.live_active.as_deref()==Some(id)&&g.live_generation==generation}
fn emit_state(app:&tauri::AppHandle,state:&Arc<Mutex<RuntimeState>>,id:&str,generation:u64,attempt:u32,phase:&str,message:String){if live_current(state,id,generation){emit_live(app,LiveEvent{task_id:id.into(),generation,attempt,phase:phase.into(),message,stream_url:None,protocol:None,cdn:None,health:None,latency_ms:None,playback:None,candidates:vec![]});}}
fn reap_child(mut c:Child){
    let _=c.kill();
    let _=c.wait();
}
fn stop_native(state: &Arc<Mutex<RuntimeState>>) -> bool {
    let state_guard = state.lock().unwrap();
    let mut p = state_guard.playback.lock().unwrap();
    if let Some(mut engine) = p.take() {
        let _ = player::stop(&mut engine);
        player::destroy_native_surface();
        true
    } else { false }
}

#[tauri::command]
fn player_backend() -> String { player::backend_name().into() }

#[tauri::command]
fn player_ffmpeg_status(state: State<AppState>) -> player::FfmpegStatus {
    let g = state.0.lock().unwrap();
    let p = g.playback.lock().unwrap();
    player::ffmpeg_status(p.as_ref())
}

#[tauri::command]
fn player_embed_tick(state: State<AppState>) {
    let state_guard = state.0.lock().unwrap();
    let mut p = state_guard.playback.lock().unwrap();
    if let Some(engine) = p.as_mut() { let _ = player::poll(engine); }
}

#[tauri::command]
fn dock_native_player(app: tauri::AppHandle, x: i32, y: i32, w: i32, h: i32) -> Result<(), String> {
    let window=app.get_webview_window("main").ok_or("main window not found")?;
    let handle=window.window_handle().map_err(|e|format!("native window handle: {e}"))?;
    let native=match handle.as_raw() {
        #[cfg(target_os="macos")] RawWindowHandle::AppKit(h) => h.ns_view.as_ptr() as *mut std::ffi::c_void,
        #[cfg(target_os="windows")] RawWindowHandle::Win32(h) => h.hwnd.get() as *mut std::ffi::c_void,
        _ => return Err("native player surface is only implemented for macOS/Windows".into()),
    };
    let scale=window.scale_factor().unwrap_or(1.0); player::dock_native_surface(native, lixh_player_core::surface::SurfaceRect { x:x as f64, y:y as f64, width:w.max(1) as f64, height:h.max(1) as f64, device_scale:scale })
}

fn start_live_worker(state:Arc<Mutex<RuntimeState>>,job:LiveJob){
    let app=job.reply.clone(); let task=job.id.clone(); let generation=job.generation; let room=job.room_url.clone();
    const MAX_RECONNECT:u32=5;
    'reconnect: for attempt in 0..=MAX_RECONNECT {
        if !live_current(&state,&task,generation){return;}
        emit_live(&app,LiveEvent{task_id:task.clone(),generation,attempt,phase:"resolving".into(),message:if attempt==0{"后台解析直播源（lixh-stream-resolver）…".into()}else{format!("第 {attempt} 次重连：重新解析直播源…")},stream_url:None,protocol:None,cdn:None,health:None,latency_ms:None,playback:None,candidates:vec![]});
        let resolved=match resolve(&app,&room){
            Ok(x)=>x,
            Err(e)=>{
                if is_ended_err(&e){
                    emit_state(&app,&state,&task,generation,attempt,"ended",e);
                    break 'reconnect;
                }
                if attempt<MAX_RECONNECT{emit_state(&app,&state,&task,generation,attempt,"reconnecting",format!("解析失败：{e}，准备重连"));thread::sleep(Duration::from_millis(700u64.saturating_mul((attempt+1) as u64)));continue 'reconnect}
                emit_state(&app,&state,&task,generation,attempt,"error",format!("解析失败：{e}"));break 'reconnect
            }
        };
        if !resolved.is_live {
            emit_state(&app,&state,&task,generation,attempt,"ended","解析结果显示直播已结束".into());
            break 'reconnect;
        }
        if !live_current(&state,&task,generation){return;}
        let mut streams=resolved.streams.clone();
        streams.retain(|x| !x.audio_only && !x.url.contains("only_audio=1"));
        streams.sort_by(|a,b| a.priority.cmp(&b.priority).then_with(|| b.bitrate.cmp(&a.bitrate)));
        if streams.is_empty(){
            emit_state(&app,&state,&task,generation,attempt,"error","解析器没有返回可播放的视频流".into());
            break 'reconnect;
        }
        if streams.iter().any(|x| x.format.to_ascii_lowercase().contains("flv")){
            streams.retain(|x| x.format.to_ascii_lowercase().contains("flv"));
        }
        streams.truncate(3);
        let cs:Vec<Candidate>=streams.iter().map(|x|{
            let protocol=if x.format.to_ascii_lowercase().contains("flv"){"FLV"}else{"HLS"};
            let host=url::Url::parse(&x.url).ok().and_then(|u|u.host_str().map(str::to_owned)).unwrap_or_else(||"-".into());
            Candidate{url:x.url.clone(),protocol:protocol.into(),host,latency:0,status:"resolver-selected".into(),score:100000-(x.priority as i64)*1000}
        }).collect();
        emit_live(&app,LiveEvent{task_id:task.clone(),generation,attempt,phase:"resolved".into(),message:format!("lixh-stream-resolver 返回 {} 个候选源",streams.len()),stream_url:None,protocol:None,cdn:None,health:None,latency_ms:None,playback:None,candidates:cs.clone()});
        let resolved_for_engine=lixh_stream_resolver::ResolvedStream{streams:streams.clone(),..resolved};
        // ---- lixh-stream-stack 0.9 → playback-engine → player-host → lixh-player-core ----
        'candidate: for (candidate_index,best) in cs.iter().enumerate(){
            if !live_current(&state,&task,generation){stop_native(&state);return;}
            let phase=if candidate_index==0{"starting_player"}else{"source_switching"};
            let msg=if candidate_index==0{"启动 lixh-player-core…".into()}else{format!("切换候选源 #{}",candidate_index+1)};
            emit_live(&app,LiveEvent{task_id:task.clone(),generation,attempt,phase:phase.into(),message:msg,stream_url:Some(best.url.clone()),protocol:Some(best.protocol.clone()),cdn:Some(best.host.clone()),health:Some(best.status.clone()),latency_ms:Some(best.latency),playback:None,candidates:cs.clone()});
            stop_native(&state);
            let selected=resolved_for_engine.streams.iter().find(|x| x.url==best.url).cloned();
            let mut engine=match selected {
                Some(selected)=>{
                    let r=lixh_stream_resolver::ResolvedStream{streams:vec![selected],..resolved_for_engine.clone()};
                    player::create_resolved(r)
                }
                None=>Err("候选源已失效".into()),
            };
            let mut engine=match engine {
                Ok(x)=>x,
                Err(e)=>{ if candidate_index+1<streams.len(){continue 'candidate;} emit_state(&app,&state,&task,generation,attempt,"error",e); break 'reconnect; }
            };
            if let Err(e)=player::start(&mut engine){
                if candidate_index+1<cs.len(){continue 'candidate;}
                if attempt<MAX_RECONNECT{emit_state(&app,&state,&task,generation,attempt,"reconnecting",format!("播放器启动失败：{e}"));thread::sleep(Duration::from_millis(700));continue 'reconnect;}
                emit_state(&app,&state,&task,generation,attempt,"error",e);break 'reconnect;
            }
            {let mut g=state.lock().unwrap(); *g.playback.lock().unwrap()=Some(engine); g.room_url=Some(room.clone()); g.last_stream_url=Some(best.url.clone()); g.live_retry=attempt;}
            emit_live(&app,LiveEvent{task_id:task.clone(),generation,attempt,phase:"playing".into(),message:format!("lixh-player-core · {}",best.protocol),stream_url:Some(best.url.clone()),protocol:Some(best.protocol.clone()),cdn:Some(best.host.clone()),health:Some(best.status.clone()),latency_ms:Some(best.latency),playback:None,candidates:cs.clone()});
            loop {
                thread::sleep(Duration::from_millis(800));
                if !live_current(&state,&task,generation){stop_native(&state);return;}
                let alive={let mut g=state.lock().unwrap();let mut p=g.playback.lock().unwrap();if let Some(e)=p.as_mut(){let _=player::poll(e);player::alive(e)}else{false}};
                if !alive{
                    if candidate_index+1<cs.len(){continue 'candidate;}
                    if attempt<MAX_RECONNECT{emit_state(&app,&state,&task,generation,attempt,"reconnecting","lixh-player-core 解码退出，重连…".into());break 'candidate;}
                    emit_state(&app,&state,&task,generation,attempt,"player_exit","lixh-player-core 已退出".into());break 'reconnect;
                }
            }
        }
        continue 'reconnect;
    }
    let mut g=state.lock().unwrap();if g.live_active.as_deref()==Some(&task)&&g.live_generation==generation{g.live_active=None;}
}
fn ensure_live_worker(state:&State<AppState>)->mpsc::SyncSender<LiveJob>{let mut g=state.0.lock().unwrap();if let Some(tx)=&g.live_tx{return tx.clone()}let(tx,rx)=mpsc::sync_channel::<LiveJob>(4);let shared=state.0.clone();thread::spawn(move||{for job in rx{start_live_worker(shared.clone(),job);}});g.live_tx=Some(tx.clone());tx}

#[tauri::command]
fn start_live(app:tauri::AppHandle,room_url:String,state:State<AppState>)->Result<StartResult,String>{
    let room=room_url.trim().to_string();if room.is_empty(){return Err("请输入直播间地址".into())}
    let (id,generation)={
        let mut g=state.0.lock().unwrap();
        g.live_seq+=1;
        g.live_generation=g.live_generation.saturating_add(1);
        let id=format!("live-{}-{}",now_ms(),g.live_seq);
        g.live_active=Some(id.clone());
        g.live_retry=0;
        g.room_url=Some(room.clone());
        (id,g.live_generation)
    };
    let _=stop_native(&state.0);
    let tx=ensure_live_worker(&state);
    if let Err(e)=tx.try_send(LiveJob{id:id.clone(),generation,room_url:room,reply:app}){let mut g=state.0.lock().unwrap();if g.live_active.as_deref()==Some(&id)&&g.live_generation==generation{g.live_active=None;}return Err(format!("直播后台任务入队失败：{e}"));}
    Ok(StartResult{task_id:id,status:"queued".into(),message:format!("直播解析任务已后台启动 generation={generation}")})
}
#[tauri::command]
fn stop_player(app:tauri::AppHandle,state:State<AppState>)->bool{
    let stopped=stop_native(&state.0);
    let mut g=state.0.lock().unwrap();
    g.live_generation=g.live_generation.saturating_add(1);
    g.live_active=None;
    g.live_retry=0;
    g.last_stream_url=None;
    stopped
}
#[tauri::command]
fn player_alive(state:State<AppState>)->bool{ let g=state.0.lock().unwrap(); let p=g.playback.lock().unwrap(); p.as_ref().map(player::alive).unwrap_or(false) }
#[tauri::command]fn current_room(state:State<AppState>)->Option<String>{state.0.lock().unwrap().room_url.clone()}
#[tauri::command]fn clear_room(app:tauri::AppHandle,state:State<AppState>){
    let _=stop_native(&state.0);
    stop_native(&state.0);
    let mut g=state.0.lock().unwrap();
    g.live_generation=g.live_generation.saturating_add(1);
    g.live_active=None;
    g.room_url=None;
    g.last_stream_url=None;
    g.live_retry=0;
}

#[derive(Clone,Serialize)] struct Q1PluginInfo{id:String,name:String,version:String,protocol:String,entry:String,platforms:Vec<String>,capabilities:Vec<String>,manifest:String,executable:String,available:bool,message:String}
fn plugin_roots(app:Option<&tauri::AppHandle>)->Vec<PathBuf>{
    let mut v=vec![];
    if let Some(app)=app{
        if let Ok(d)=app.path().resource_dir(){
            v.push(d.join("tools").join("plugins"));
        }
    }
    if let Ok(cur)=env::current_exe(){
        if let Some(d)=cur.parent(){
            v.push(d.join("tools").join("plugins"));
            #[cfg(target_os="macos")]
            v.push(d.join("../Resources/tools/plugins"));
        }
    }
    if let Ok(cwd)=env::current_dir(){
        v.push(cwd.join("tools").join("plugins"));
        v.push(cwd.join("src-tauri").join("tools").join("plugins"));
    }
    v
}
fn adapter_entry_names(entry:&str)->Vec<String>{
    let mut names=Vec::new();
    if cfg!(windows){
        if !entry.ends_with(".exe"){names.push(format!("{entry}.exe"));}
        if !entry.ends_with(".cmd"){names.push(format!("{entry}.cmd"));}
        if !entry.ends_with(".py"){names.push(format!("{entry}.py"));}
    }
    names.push(entry.to_string());
    names
}
fn resolve_plugin_entry(dir:&PathBuf,entry:&str)->PathBuf{
    for name in adapter_entry_names(entry){
        let p=dir.join(&name);
        if p.is_file(){return p}
    }
    dir.join(if cfg!(windows){format!("{entry}.exe")}else{entry.to_string()})
}
fn adapter_path(app:Option<&tauri::AppHandle>,platform:&str)->Option<PathBuf>{
    if let Ok(x)=env::var("LIVECATCH_Q1_ADAPTER"){
        let p=PathBuf::from(x);
        if p.is_file(){return Some(p)}
    }
    if let Some(info)=q1_plugin(app,platform){
        let p=PathBuf::from(&info.executable);
        if p.is_file(){return Some(p)}
    }
    // Direct fallback: tools/plugins/q1-<platform>/q1-adapter(.exe|.cmd|script)
    let names=adapter_entry_names("q1-adapter");
    for root in plugin_roots(app){
        let plugin_dir=root.join(format!("q1-{platform}"));
        for name in &names{
            let p=plugin_dir.join(name);
            if p.is_file(){return Some(p)}
        }
        if let Ok(entries)=fs::read_dir(&root){
            for e in entries.flatten(){
                for name in &names{
                    let cand=e.path().join(name);
                    if cand.is_file(){return Some(cand)}
                }
            }
        }
    }
    for name in &names{
        if let Some(p)=exe_candidates(app,name).into_iter().find(|p|p.is_file()){
            return Some(p);
        }
    }
    None
}
fn plugin_manifest(app:Option<&tauri::AppHandle>,platform:&str)->Option<Q1PluginInfo>{
    for root in plugin_roots(app){
        let entries=match fs::read_dir(&root){Ok(x)=>x,Err(_)=>continue};
        for e in entries.flatten(){
            let dir=e.path();
            if !dir.is_dir(){continue}
            let mf=dir.join("manifest.json");
            let raw=match fs::read_to_string(&mf){Ok(x)=>x,Err(_)=>continue};
            let v:serde_json::Value=match serde_json::from_str(&raw){Ok(x)=>x,Err(_)=>continue};
            let platforms=v.get("platforms").and_then(|x|x.as_array()).map(|a|a.iter().filter_map(|x|x.as_str().map(str::to_owned)).collect::<Vec<_>>()).unwrap_or_default();
            if !platforms.is_empty()&&!platforms.iter().any(|x|x==platform){continue}
            let entry=v.get("entry").and_then(|x|x.as_str()).unwrap_or("q1-adapter");
            let ep=resolve_plugin_entry(&dir,entry);
            let available=ep.is_file();
            return Some(Q1PluginInfo{
                id:v.get("id").and_then(|x|x.as_str()).unwrap_or("unknown").into(),
                name:v.get("name").and_then(|x|x.as_str()).unwrap_or("Q1 Adapter").into(),
                version:v.get("version").and_then(|x|x.as_str()).unwrap_or("0.0.0").into(),
                protocol:v.get("protocol").and_then(|x|x.as_str()).unwrap_or("livecatch.q1.jsonl.v1").into(),
                entry:entry.into(),
                platforms,
                capabilities:v.get("capabilities").and_then(|x|x.as_array()).map(|a|a.iter().filter_map(|x|x.as_str().map(str::to_owned)).collect()).unwrap_or_default(),
                manifest:mf.display().to_string(),
                executable:ep.display().to_string(),
                available,
                message:if available{"插件已安装".into()}else{"插件清单存在，但未安装 Adapter 可执行文件".into()},
            });
        }
    }
    None
}
fn q1_plugin(app:Option<&tauri::AppHandle>,platform:&str)->Option<Q1PluginInfo>{plugin_manifest(app,platform)}
fn tools_roots(app:&tauri::AppHandle)->Vec<PathBuf>{
    let mut v=vec![];
    if let Ok(d)=app.path().resource_dir(){
        v.push(d.join("tools"));
        v.push(d.join("tools").join("windows"));
    }
    if let Ok(cur)=env::current_exe(){
        if let Some(d)=cur.parent(){
            v.push(d.join("tools"));
            v.push(d.join("tools").join("windows"));
            #[cfg(target_os="macos")]
            {
                v.push(d.join("../Resources/tools"));
                v.push(d.join("../Resources/tools/windows"));
            }
        }
    }
    if let Ok(cwd)=env::current_dir(){
        v.push(cwd.join("tools"));
        v.push(cwd.join("src-tauri").join("tools"));
        v.push(cwd.join("src-tauri").join("tools").join("windows"));
    }
    v
}
fn venv_python_in(dir:&PathBuf)->Option<PathBuf>{
    #[cfg(windows)]
    let cand=dir.join(".venv").join("Scripts").join("python.exe");
    #[cfg(not(windows))]
    let cand=dir.join(".venv").join("bin").join("python");
    if cand.is_file(){Some(cand)}else{None}
}
fn find_plugin_venv_python(adapter:Option<&PathBuf>)->Option<PathBuf>{
    let mut dirs=Vec::new();
    if let Some(p)=adapter{
        if let Some(d)=p.parent(){dirs.push(d.to_path_buf());}
    }
    if let Ok(cwd)=env::current_dir(){
        dirs.push(cwd.join("tools").join("plugins").join("q1-douyin"));
        dirs.push(cwd.join("src-tauri").join("tools").join("plugins").join("q1-douyin"));
        dirs.push(cwd.join("..").join("tools").join("plugins").join("q1-douyin"));
    }
    for dir in dirs{
        if let Some(py)=venv_python_in(&dir){return Some(py)}
    }
    None
}
fn find_bundled_python(app:&tauri::AppHandle,adapter:Option<&PathBuf>)->Option<PathBuf>{
    if let Ok(x)=env::var("LIVECATCH_PYTHON"){
        let p=PathBuf::from(x);
        if p.is_file(){return Some(p)}
    }
    // 插件目录 .venv（mac 开发：规避 Homebrew PEP668 无 httpx）
    if let Some(py)=find_plugin_venv_python(adapter){return Some(py)}
    // Windows 安装包：只用捆绑的 embeddable CPython（切勿在 macOS 上执行 .exe）
    if cfg!(windows){
        for root in tools_roots(app){
            for cand in [
                root.join("python").join("python.exe"),
                root.join("windows").join("python").join("python.exe"),
                root.join("python.exe"),
            ]{
                if cand.is_file(){return Some(cand)}
            }
        }
    }
    // 最后才用系统 Python（可能没有 httpx）
    for name in ["python3","python"]{
        if Command::new(name).arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s|s.success()).unwrap_or(false){
            return Some(PathBuf::from(name));
        }
    }
    None
}
fn find_bundled_node(app:&tauri::AppHandle)->Option<PathBuf>{
    if let Ok(x)=env::var("LIVECATCH_NODE"){
        let p=PathBuf::from(x);
        if p.is_file(){return Some(p)}
    }
    // 仅 Windows 包内 node.exe；mac 开发用系统 node，绝不把 win 的 node.exe 塞进 PATH
    if cfg!(windows){
        for root in tools_roots(app){
            for cand in [
                root.join("node").join("node.exe"),
                root.join("windows").join("node").join("node.exe"),
                root.join("node.exe"),
            ]{
                if cand.is_file(){return Some(cand)}
            }
        }
    }
    None
}
fn is_python_adapter(p:&PathBuf)->bool{
    let name=p.file_name().and_then(|s|s.to_str()).unwrap_or("").to_ascii_lowercase();
    if name.ends_with(".py"){return true}
    if name.ends_with(".exe")||name.ends_with(".cmd")||name.ends_with(".bat"){return false}
    if let Ok(raw)=fs::read(p){
        let head=String::from_utf8_lossy(&raw[..raw.len().min(80)]);
        if head.starts_with("#!") && head.to_ascii_lowercase().contains("python"){return true}
    }
    name=="q1-adapter"
}
fn start_daemon(p:&PathBuf,app:tauri::AppHandle)->Result<Q1Daemon,String>{
    let mut c=if is_python_adapter(p){
        // 一律用显式解释器：优先插件 .venv → Windows 捆绑 → 系统 python
        // （mac shebang 常落到 Homebrew python3，缺 httpx 导致弹幕模块加载失败）
        let py=find_bundled_python(&app,Some(p)).ok_or_else(||{
            "未找到 Python 运行时：请在 tools/plugins/q1-douyin 创建 .venv 并 pip install -r requirements.txt".to_string()
        })?;
        let mut cmd=Command::new(py);
        cmd.arg(p).arg("--stdio");
        cmd
    }else if p.extension().and_then(|s|s.to_str()).map(|s|s.eq_ignore_ascii_case("cmd")||s.eq_ignore_ascii_case("bat")).unwrap_or(false){
        let mut cmd=Command::new("cmd");
        cmd.arg("/C").arg(p).arg("--stdio");
        cmd
    }else{
        let mut cmd=Command::new(p);
        cmd.arg("--stdio");
        cmd
    };
    // Ensure bundled Node is visible to sign.js (Windows package only)
    if let Some(node)=find_bundled_node(&app){
        if let Some(dir)=node.parent(){
            let sep=if cfg!(windows){";"}else{":"};
            let old=env::var("PATH").unwrap_or_default();
            let new_path=format!("{}{}{}", dir.display(), sep, old);
            c.env("PATH", new_path);
            c.env("LIVECATCH_NODE", &node);
        }
    }
    if let Some(dir)=p.parent(){
        c.current_dir(dir);
    }
    let mut child=c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e|format!("启动 Adapter 失败：{e} ({})", p.display()))?;
    let stdin=match child.stdin.take(){Some(x)=>x,None=>{reap_child(child);return Err("stdin unavailable".into())}};
    let stdout=match child.stdout.take(){Some(x)=>x,None=>{reap_child(child);return Err("stdout unavailable".into())}};
    let(tx,rx)=mpsc::channel();
    let app_emit=app.clone();
    // Split async event lines (danmaku) from request/response lines.
    thread::spawn(move||{
        let mut r=BufReader::new(stdout);
        loop{
            let mut line=String::new();
            match r.read_line(&mut line){
                Ok(0)|Err(_)=>break,
                Ok(_)=>{
                    let trim=line.trim();
                    if trim.is_empty(){continue}
                    if let Ok(v)=serde_json::from_str::<serde_json::Value>(trim){
                        if v.get("event").and_then(|x|x.as_str())==Some("danmaku"){
                            let _=app_emit.emit("danmaku-event", v);
                            continue;
                        }
                    }
                    if tx.send(line).is_err(){break}
                }
            }
        }
    });
    Ok(Q1Daemon{child,stdin,rx})
}
fn daemon_send(d:&mut Q1Daemon,v:&serde_json::Value)->Result<(String,String),String>{
    if let Ok(Some(status))=d.child.try_wait(){return Err(format!("Q1 Adapter 已退出：{status}"))}
    let action=v.get("action").and_then(|x|x.as_str()).unwrap_or("");
    let want_id=v.get("request_id").and_then(|x|x.as_str()).unwrap_or("").to_string();
    let timeout=if action=="subscribe_danmaku"||action=="connect"{
        Duration::from_secs(60)
    }else if action=="send_text"||action=="send_product"{
        QTIME_SEND
    }else{
        QTIME
    };
    let line=serde_json::to_string(v).map_err(|e|e.to_string())?+"\n";
    d.stdin.write_all(line.as_bytes()).and_then(|_|d.stdin.flush()).map_err(|e|e.to_string())?;
    let deadline=Instant::now()+timeout;
    loop{
        let left=deadline.saturating_duration_since(Instant::now());
        if left.is_zero(){
            return Err(format!("Q1 Adapter 超时（{action}，{}s）— 进程仍在，弹幕不断", timeout.as_secs()));
        }
        let line=d.rx.recv_timeout(left).map_err(|_|{
            format!("Q1 Adapter 超时（{action}，{}s）— 进程仍在，弹幕不断", timeout.as_secs())
        })?;
        let x:serde_json::Value=serde_json::from_str(line.trim()).map_err(|e|e.to_string())?;
        let rid=x.get("request_id").and_then(|x|x.as_str()).unwrap_or("");
        // Discard stale replies from a previous timed-out job so they don't poison the next call.
        if !want_id.is_empty() && !rid.is_empty() && rid!=want_id{
            continue;
        }
        return Ok((x.get("status").and_then(|x|x.as_str()).unwrap_or("failed").into(),x.get("message").and_then(|x|x.as_str()).unwrap_or("").into()));
    }
}
fn hist(g:&mut RuntimeState,r:Q1Record){if g.q1_history.len()>=HC{g.q1_history.pop_front();}g.q1_history.push_back(r)}
fn percentile(g:&RuntimeState,p:f64)->u128{let mut v:Vec<u128>=g.q1_history.iter().filter(|r|r.status=="sent").map(|r|r.send_ms).collect();if v.is_empty(){return 0}v.sort_unstable();v[((v.len()-1) as f64*p).ceil() as usize]}
fn adapter_health(shared:&Arc<Mutex<RuntimeState>>,healthy:bool,pid:Option<u32>){let mut g=shared.lock().unwrap();g.q1_adapter_healthy=healthy;g.q1_adapter_pid=pid;}
fn ensure_worker(app:tauri::AppHandle,state:&State<AppState>)->mpsc::SyncSender<Q1Job>{let mut g=state.0.lock().unwrap();if let Some(tx)=&g.q1_tx{return tx.clone()}let(tx,rx)=mpsc::sync_channel::<Q1Job>(QCAP);let shared=state.0.clone();thread::spawn(move||{let mut daemon:Option<Q1Daemon>=None;for job in rx{let id=job.id.clone();let cancelled={let mut g=shared.lock().unwrap();g.q1_queued_ids.remove(&id);g.q1_queued=g.q1_queued.saturating_sub(1);g.q1_cancelled.remove(&id)};if cancelled{let r=Q1Record{request_id:id.clone(),code:job.payload["code"].as_str().unwrap_or("").into(),name:job.payload["name"].as_str().unwrap_or("").into(),qty:job.payload["qty"].as_i64().unwrap_or(1) as i32,status:"cancelled".into(),message:"排队任务已取消".into(),queued_ms:now_ms().saturating_sub(job.client_ts_ms),adapter_ms:0,send_ms:0,time:now()};{let mut g=shared.lock().unwrap();hist(&mut g,r)}let _=job.reply.emit("q1-result",serde_json::json!({"request_id":id,"status":"cancelled","message":"排队任务已取消","send_ms":0}));continue;}let queued_ms=now_ms().saturating_sub(job.client_ts_ms);{let mut g=shared.lock().unwrap();g.q1_inflight=true;g.q1_active=Some(id.clone());}let adapter_started=Instant::now();let mut status="failed".to_string();let mut msg=String::new();if daemon.is_none(){if let Some(path)=adapter_path(Some(&app),&detect_platform(&job.payload["room_url"].as_str().unwrap_or(""))){match start_daemon(&path,app.clone()){Ok(d)=>{let pid=d.child.id();adapter_health(&shared,true,Some(pid));daemon=Some(d)},Err(e)=>{adapter_health(&shared,false,None);msg=format!("Adapter 启动失败：{e}")}}}else{adapter_health(&shared,false,None);msg="未安装 Q1 Adapter".into();status="not_sent".into();} }if let Some(d)=daemon.as_mut(){if msg.is_empty(){match daemon_send(d,&job.payload){Ok((s,m))=>{status=s;msg=m},Err(e)=>{msg=e.clone();
// Soft timeout: keep daemon alive so direct WSS danmaku is not killed.
// Hard fail (process dead / stdin broken): restart next job.
let hard=msg.contains("已退出")||msg.contains("Broken pipe")||msg.contains("os error");
if hard{d.kill_wait();daemon=None;let mut g=shared.lock().unwrap();g.q1_adapter_healthy=false;g.q1_adapter_pid=None;g.q1_adapter_restarts+=1;}
}}}}let adapter_ms=adapter_started.elapsed().as_millis();let total_ms=now_ms().saturating_sub(job.client_ts_ms);let r=Q1Record{request_id:id.clone(),code:job.payload["code"].as_str().unwrap_or("").into(),name:job.payload["name"].as_str().unwrap_or("").into(),qty:job.payload["qty"].as_i64().unwrap_or(1) as i32,status:status.clone(),message:msg.clone(),queued_ms,adapter_ms,send_ms:total_ms,time:now()};{let mut g=shared.lock().unwrap();g.q1_inflight=false;g.q1_active=None;g.q1_last_ms=Some(total_ms);hist(&mut g,r)}let _=job.reply.emit("q1-result",serde_json::json!({"request_id":id,"status":status,"message":msg,"send_ms":total_ms,"queued_ms":queued_ms,"adapter_ms":adapter_ms,"code":job.payload["code"],"name":job.payload["name"],"qty":job.payload["qty"]}));
// Danmaku subscribe saw ended room → sync monitor UI + stop native player.
if id.starts_with("dm-sub-") && (status=="failed"||status=="error") && msg.contains("直播已结束"){
    let _=stop_native(&shared);
    {let mut g=shared.lock().unwrap();g.live_active=None;}
    let _=job.reply.emit("live-event",LiveEvent{task_id:id.clone(),generation:0,attempt:0,phase:"ended".into(),message:msg.clone(),stream_url:None,protocol:None,cdn:None,health:None,latency_ms:None,playback:None,candidates:vec![]});
}
}});g.q1_tx=Some(tx.clone());tx}
#[tauri::command]fn send_q1(app:tauri::AppHandle,room_url:String,code:String,name:String,qty:i32,request_id:Option<String>,state:State<AppState>)->Result<Q1Result,String>{if qty<=0{return Err("数量必须大于 0".into())}if room_url.trim().is_empty(){return Err("请先连接直播间".into())}if adapter_path(Some(&app),&detect_platform(&room_url)).is_none(){return Err("未安装 Q1 Adapter，请先配置 Adapter".into())}let id=request_id.filter(|x|!x.trim().is_empty()).unwrap_or_else(||format!("q1-{}-{}",now_ms(),Q1_REQUEST_SEQ.fetch_add(1,Ordering::Relaxed)));let tx=ensure_worker(app.clone(),&state);let client_ts_ms=now_ms();{let mut g=state.0.lock().unwrap();if g.q1_history.iter().any(|r|r.request_id==id)||g.q1_active.as_deref()==Some(&id)||g.q1_queued_ids.contains(&id){return Ok(Q1Result{request_id:id,status:"duplicate".into(),transport:"dedupe".into(),send_ms:0,message:"request_id 已存在或正在排队".into()})}if g.q1_queued>=QCAP{return Err("Q1 队列已满（64）".into())}g.q1_queued+=1;g.q1_queued_ids.insert(id.clone());}let payload=serde_json::json!({"action":"send_product","platform":detect_platform(&room_url),"room_url":room_url,"code":code,"name":name,"qty":qty,"text":"1","request_id":id,"client_ts_ms":client_ts_ms});if let Err(e)=tx.try_send(Q1Job{id:id.clone(),payload,reply:app,client_ts_ms}){let mut g=state.0.lock().unwrap();g.q1_queued=g.q1_queued.saturating_sub(1);g.q1_queued_ids.remove(&id);return Err(format!("Q1 入队失败：{e}"))}Ok(Q1Result{request_id:id,status:"queued".into(),transport:"queue".into(),send_ms:0,message:"Q1 已入队".into()})}
#[tauri::command]fn cancel_q1(request_id:String,state:State<AppState>)->Result<bool,String>{let mut g=state.0.lock().unwrap();if g.q1_active.as_deref()==Some(&request_id){return Ok(false)}if g.q1_history.iter().any(|r|r.request_id==request_id){return Ok(false)}if g.q1_queued_ids.contains(&request_id){g.q1_cancelled.insert(request_id);return Ok(true)}Ok(false)}
fn q1_products_file(app:Option<&tauri::AppHandle>,platform:&str)->Option<PathBuf>{q1_plugin(app,platform).map(|x|PathBuf::from(x.manifest).parent().unwrap_or(std::path::Path::new(".")).join("products.json"))}
#[tauri::command]fn q1_products(app:tauri::AppHandle,room_url:Option<String>)->Result<Vec<Q1ProductMap>,String>{let platform=room_url.as_deref().map(detect_platform).unwrap_or_else(||"douyin".into());let path=q1_products_file(Some(&app),&platform).ok_or("未找到 Q1 插件")?;let raw=fs::read_to_string(&path).map_err(|e|format!("读取商品映射失败：{e}"))?;let v:serde_json::Value=serde_json::from_str(&raw).map_err(|e|format!("商品映射 JSON 无效：{e}"))?;let mut out=vec![];if let Some(o)=v.as_object(){for (code,id) in o{if let Some(n)=id.as_i64(){out.push(Q1ProductMap{code:code.clone(),product_id:n})}}}out.sort_by(|a,b|a.code.cmp(&b.code));Ok(out)}
#[tauri::command]fn q1_set_product(app:tauri::AppHandle,room_url:Option<String>,code:String,product_id:i64)->Result<Vec<Q1ProductMap>,String>{if code.trim().is_empty(){return Err("商品编码不能为空".into())}if product_id<=0{return Err("商品 ID 必须大于 0".into())}let platform=room_url.as_deref().map(detect_platform).unwrap_or_else(||"douyin".into());let path=q1_products_file(Some(&app),&platform).ok_or("未找到 Q1 插件")?;let raw=if path.is_file(){fs::read_to_string(&path).unwrap_or_else(|_|"{}".into())}else{"{}".into()};let mut v:serde_json::Value=serde_json::from_str(&raw).unwrap_or_else(|_|serde_json::json!({}));if !v.is_object(){v=serde_json::json!({})}v.as_object_mut().unwrap().insert(code.trim().to_string(),serde_json::json!(product_id));fs::write(&path,serde_json::to_string_pretty(&v).map_err(|e|e.to_string())?).map_err(|e|format!("保存商品映射失败：{e}"))?;q1_products(app,Some(if platform=="douyin"{"https://douyin.com".into()}else{format!("https://{}.com",platform)}))}
#[tauri::command]fn q1_status(app:tauri::AppHandle,room_url:Option<String>,state:State<AppState>)->Q1Status{let platform=room_url.as_deref().map(detect_platform).unwrap_or_else(||"unknown".into());let plugin=q1_plugin(Some(&app),&platform);let adapter=adapter_path(Some(&app),&platform);let available=adapter.is_some();let adapter_s=adapter.as_ref().map(|p|p.display().to_string()).unwrap_or_default();let g=state.0.lock().unwrap();Q1Status{available,adapter:adapter_s,platform:platform.clone(),message:if available{"Q1 插件已就绪".into()}else if plugin.is_some(){"Q1 插件清单已发现，但缺少 Adapter 可执行文件".into()}else{"未配置 Q1 Adapter 插件".into()},plugin, queued:g.q1_queued,inflight:g.q1_inflight,active:g.q1_active.clone(),adapter_healthy:g.q1_adapter_healthy,adapter_pid:g.q1_adapter_pid,adapter_restarts:g.q1_adapter_restarts,history:g.q1_history.iter().cloned().collect(),p50_ms:percentile(&g,0.5),p95_ms:percentile(&g,0.95),p99_ms:percentile(&g,0.99)}}

#[derive(Serialize)] struct ToolInfo{name:String,available:bool,path:String,version:String,message:String}
fn tool_info(app:&tauri::AppHandle,n:&str)->ToolInfo{
    let path=match find_exe(Some(app),n){Ok(p)=>p,Err(e)=>return ToolInfo{name:n.into(),available:false,path:String::new(),version:String::new(),message:e}};
    let out=Command::new(&path).arg("--version").output();
    let version=match out{Ok(o)=>{let text=String::from_utf8_lossy(&o.stdout).trim().to_string();if text.is_empty(){String::from_utf8_lossy(&o.stderr).trim().to_string()}else{text}},Err(e)=>format!("版本检测失败：{e}")};
    ToolInfo{name:n.into(),available:true,path:path.display().to_string(),version,message:"已找到".into()}
}
#[tauri::command]fn tool_status(app:tauri::AppHandle)->Vec<ToolInfo>{
    let resolver=ToolInfo{name:"lixh-stream-resolver".into(),available:true,path:"内置 Rust resolver".into(),version:"0.1.2 / rust-srec 7da2f5a7".into(),message:"解析核心已内置调用链，不依赖 strev 可执行文件".into()};
    vec![resolver,ToolInfo{name:"q1-plugin".into(),available:q1_plugin(Some(&app),"douyin").map(|x|x.available).unwrap_or(false),path:q1_plugin(Some(&app),"douyin").map(|x|x.executable).unwrap_or_default(),version:q1_plugin(Some(&app),"douyin").map(|x|x.version).unwrap_or_default(),message:q1_plugin(Some(&app),"douyin").map(|x|x.message).unwrap_or_else(||"未发现 Q1 插件清单".into())}]
}
#[tauri::command]fn environment()->String{if cfg!(target_os="macos"){"macOS".into()}else if cfg!(windows){"Windows".into()}else{"Other".into()}}
#[tauri::command]fn app_version()->String{"0.47.8".into()}
#[tauri::command]fn subscribe_danmaku(app:tauri::AppHandle,room_url:String,state:State<AppState>)->Result<Q1Result,String>{
    let room=room_url.trim().to_string();
    if room.is_empty(){return Err("请先连接直播间".into())}
    if adapter_path(Some(&app),&detect_platform(&room)).is_none(){return Err("未安装公屏 Adapter（tools/plugins/q1-douyin）".into())}
    let id=format!("dm-sub-{}-{}",now_ms(),Q1_REQUEST_SEQ.fetch_add(1,Ordering::Relaxed));
    let tx=ensure_worker(app.clone(),&state);
    let client_ts_ms=now_ms();
    let payload=serde_json::json!({"action":"subscribe_danmaku","platform":detect_platform(&room),"room_url":room,"request_id":id,"client_ts_ms":client_ts_ms});
    {let mut g=state.0.lock().unwrap();g.q1_queued+=1;g.q1_queued_ids.insert(id.clone());}
    if let Err(e)=tx.try_send(Q1Job{id:id.clone(),payload,reply:app,client_ts_ms}){
        let mut g=state.0.lock().unwrap();g.q1_queued=g.q1_queued.saturating_sub(1);g.q1_queued_ids.remove(&id);
        return Err(format!("弹幕订阅入队失败：{e}"));
    }
    Ok(Q1Result{request_id:id,status:"queued".into(),transport:"queue".into(),send_ms:0,message:"弹幕订阅已入队".into()})
}
#[tauri::command]fn unsubscribe_danmaku(app:tauri::AppHandle,state:State<AppState>)->Result<Q1Result,String>{
    let id=format!("dm-unsub-{}-{}",now_ms(),Q1_REQUEST_SEQ.fetch_add(1,Ordering::Relaxed));
    let tx=ensure_worker(app.clone(),&state);
    let client_ts_ms=now_ms();
    let room=state.0.lock().unwrap().room_url.clone().unwrap_or_else(||"https://live.douyin.com/".into());
    let payload=serde_json::json!({"action":"unsubscribe_danmaku","platform":detect_platform(&room),"room_url":room,"request_id":id,"client_ts_ms":client_ts_ms});
    {let mut g=state.0.lock().unwrap();g.q1_queued+=1;g.q1_queued_ids.insert(id.clone());}
    if let Err(e)=tx.try_send(Q1Job{id:id.clone(),payload,reply:app,client_ts_ms}){
        let mut g=state.0.lock().unwrap();g.q1_queued=g.q1_queued.saturating_sub(1);g.q1_queued_ids.remove(&id);
        return Err(format!("取消订阅入队失败：{e}"));
    }
    Ok(Q1Result{request_id:id,status:"queued".into(),transport:"queue".into(),send_ms:0,message:"取消订阅已入队".into()})
}
fn main(){tauri::Builder::default().manage(AppState(Arc::new(Mutex::new(RuntimeState{room_url:None,last_stream_url:None,q1_last_ms:None,q1_tx:None,q1_queued:0,q1_queued_ids:HashSet::new(),q1_cancelled:HashSet::new(),q1_inflight:false,q1_active:None,q1_history:VecDeque::new(),q1_adapter_healthy:false,q1_adapter_pid:None,q1_adapter_restarts:0,live_tx:None,live_seq:0,live_generation:0,live_active:None,live_retry:0,playback:Arc::new(Mutex::new(None))})))).plugin(tauri_plugin_global_shortcut::Builder::new().build()).invoke_handler(tauri::generate_handler![start_live,stop_player,player_alive,current_room,clear_room,send_q1,send_text,cancel_q1,q1_status,q1_products,q1_set_product,tool_status,environment,app_version,player_backend,player_ffmpeg_status,player_embed_tick,dock_native_player,]).run(tauri::generate_context!()).expect("error while running application");}
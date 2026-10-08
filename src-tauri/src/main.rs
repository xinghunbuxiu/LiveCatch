#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod player;
use serde::Serialize;
use std::{env, fs, path::PathBuf, process::{Command, Stdio}, sync::{mpsc, Arc, Mutex}, thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};use tauri::{Emitter, Manager, State};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

const QTIME: Duration = Duration::from_secs(8);

struct RuntimeState {
    room_url: Option<String>,
    last_stream_url: Option<String>,
    live_tx: Option<mpsc::SyncSender<LiveJob>>,
    live_seq: u64,
    live_generation: u64,
    live_active: Option<String>,
    live_retry: u32,
    playback: Arc<Mutex<Option<player::LivePlaybackEngine>>>,
}
struct AppState(Arc<Mutex<RuntimeState>>);
struct LiveJob { id:String, generation:u64, room_url:String, reply:tauri::AppHandle }
#[derive(Serialize,Clone)] struct Candidate{url:String,protocol:String,host:String,latency:u128,status:String,score:i64}
#[derive(Serialize,Clone)] struct PlaybackHealth{ipc_ok:bool,time_pos:Option<f64>,buffer_sec:Option<f64>,paused:Option<bool>,idle:Option<bool>,eof:Option<bool>,stalled:bool,buffering:bool,frame_drops:Option<u64>,decoder_frame_drops:Option<u64>,speed:Option<f64>,latency_mode:Option<String>,sample_ms:u128}
#[derive(Serialize,Clone)] struct LiveEvent{task_id:String,generation:u64,attempt:u32,phase:String,message:String,stream_url:Option<String>,protocol:Option<String>,cdn:Option<String>,health:Option<String>,latency_ms:Option<u128>,playback:Option<PlaybackHealth>,candidates:Vec<Candidate>}
#[derive(Serialize)] struct StartResult{task_id:String,status:String,message:String}

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

#[tauri::command]fn environment()->String{if cfg!(target_os="macos"){"macOS".into()}else if cfg!(windows){"Windows".into()}else{"Other".into()}}
#[tauri::command]fn app_version()->String{"0.47.8".into()}
fn main(){tauri::Builder::default().manage(AppState(Arc::new(Mutex::new(RuntimeState{room_url:None,last_stream_url:None,live_tx:None,live_seq:0,live_generation:0,live_active:None,live_retry:0,playback:Arc::new(Mutex::new(None))})))).plugin(tauri_plugin_global_shortcut::Builder::new().build()).invoke_handler(tauri::generate_handler![start_live,stop_player,player_alive,current_room,clear_room,environment,app_version,player_backend,player_ffmpeg_status,player_embed_tick,dock_native_player,]).run(tauri::generate_context!()).expect("error while running application");}
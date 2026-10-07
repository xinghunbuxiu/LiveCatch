//! LiveCatch adapter for lixh-stream-stack 0.9.
//!
//! The stack is now the only playback control path. Native video rendering is a
//! separate boundary and must never send decoded frames through Tauri IPC.

use lixh_playback_engine::{PlaybackEngine, EngineState};
use lixh_player_core::{LixhNativeFrame, LixhStats, LixhCallbacks};
use lixh_player_core::surface::{NativeSurface, SurfaceRect};
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};
use std::cell::RefCell;
use std::collections::VecDeque;
use lixh_player_host::{CorePlayerAdapter, PlayerHost};
use lixh_stream_resolver::{ResolvedStream, StreamCandidate};
use serde::Serialize;
use std::time::{SystemTime, UNIX_EPOCH};


static SURFACE: OnceLock<Mutex<Option<NativeSurface>>> = OnceLock::new();
fn surface_slot() -> &'static Mutex<Option<NativeSurface>> { SURFACE.get_or_init(|| Mutex::new(None)) }

extern "C" fn on_video(_opaque:*mut c_void, kind:i32, width:i32, height:i32, pts_ms:i64, _duration_ms:i64, frame:*const LixhNativeFrame) {
    if frame.is_null() { return; }
    let Ok(slot)=surface_slot().lock() else { return; };
    let Some(surface)=slot.as_ref() else { return; };
    let _=surface.present(unsafe{&*frame}, pts_ms);
    let _=(kind,width,height);
}


struct AudioState {
    samples: VecDeque<f32>,
    channels: usize,
    source_rate: u32,
    output_rate: u32,
    output_channels: usize,
}
static AUDIO: OnceLock<Mutex<AudioState>> = OnceLock::new();
fn audio_slot() -> &'static Mutex<AudioState> {
    AUDIO.get_or_init(|| Mutex::new(AudioState {
        samples: VecDeque::with_capacity(48000),
        channels: 2,
        source_rate: 48000,
        output_rate: 48000,
        output_channels: 2,
    }))
}

fn start_audio_output() {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    thread_local! {
        static STREAM: RefCell<Option<cpal::Stream>> = const { RefCell::new(None) };
    }
    if STREAM.with(|slot| slot.borrow().is_some()) { return; }
    let host=cpal::default_host();
    let Some(device)=host.default_output_device() else { return; };
    let Ok(supported)=device.default_output_config() else { return; };
    let cfg:cpal::StreamConfig=supported.clone().into();
    let output_channels=cfg.channels as usize;
    let output_rate=cfg.sample_rate.0.max(1);
    if let Ok(mut a)=audio_slot().lock(){
        a.output_channels=output_channels;
        a.output_rate=output_rate;
    }
    let stream=match supported.sample_format() {
        cpal::SampleFormat::F32 => device.build_output_stream(&cfg, move |out:&mut [f32],_| {
            let mut a=audio_slot().lock().unwrap();
            for sample in out.iter_mut() { *sample=a.samples.pop_front().unwrap_or(0.0); }
        }, |_e| {}, None),
        cpal::SampleFormat::I16 => device.build_output_stream(&cfg, move |out:&mut [i16],_| {
            let mut a=audio_slot().lock().unwrap();
            for sample in out.iter_mut() { *sample=(a.samples.pop_front().unwrap_or(0.0).clamp(-1.0,1.0)*i16::MAX as f32) as i16; }
        }, |_e| {}, None),
        cpal::SampleFormat::U16 => device.build_output_stream(&cfg, move |out:&mut [u16],_| {
            let mut a=audio_slot().lock().unwrap();
            for sample in out.iter_mut() { *sample=((a.samples.pop_front().unwrap_or(0.0).clamp(-1.0,1.0)*0.5+0.5)*u16::MAX as f32) as u16; }
        }, |_e| {}, None),
        _ => return,
    };
    if let Ok(stream)=stream {
        let _ = stream.play();
        STREAM.with(|slot| {
            *slot.borrow_mut() = Some(stream);
        });
    }
}

fn push_audio_resampled(src:&[f32], src_rate:u32, src_channels:usize) {
    let Ok(mut a)=audio_slot().lock() else { return; };
    let src_channels=src_channels.max(1);
    let dst_channels=a.output_channels.max(1);
    let dst_rate=a.output_rate.max(1);
    let src_rate=src_rate.max(1);
    let src_frames=src.len()/src_channels;
    if src_frames==0{return;}

    // Down/up-mix first, then linearly resample. This keeps the CPAL callback
    // cheap and guarantees that the device always consumes its native rate.
    let dst_frames=((src_frames as u64*dst_rate as u64 + src_rate as u64-1)/src_rate as u64) as usize;
    let max=48000usize*2*2;
    let needed=dst_frames.saturating_mul(dst_channels);
    if a.samples.len()+needed>max {
        let drop_n=(a.samples.len()+needed)-max;
        for _ in 0..drop_n.min(a.samples.len()){a.samples.pop_front();}
    }
    if dst_frames==1 {
        for ch in 0..dst_channels {
            let sch=ch.min(src_channels-1);
            a.samples.push_back(src[sch]);
        }
        return;
    }
    for i in 0..dst_frames {
        let pos=(i as f64)*(src_frames.saturating_sub(1) as f64)/(dst_frames.saturating_sub(1) as f64);
        let i0=pos.floor() as usize;
        let i1=(i0+1).min(src_frames-1);
        let frac=(pos-i0 as f64) as f32;
        for ch in 0..dst_channels {
            let sch=ch.min(src_channels-1);
            let a0=src[i0*src_channels+sch];
            let a1=src[i1*src_channels+sch];
            a.samples.push_back(a0+(a1-a0)*frac);
        }
    }
}

extern "C" fn on_audio(_opaque:*mut c_void, sample_rate:i32, channels:i32, _format:i32, _pts_ms:i64, samples:*const f32, sample_count:i32) {
    if samples.is_null() || sample_count<=0 || channels<=0 { return; }
    start_audio_output();
    let count=(sample_count as usize).saturating_mul(channels as usize);
    let src=unsafe{std::slice::from_raw_parts(samples,count)};
    push_audio_resampled(src,sample_rate.max(1) as u32,channels as usize);
}

fn callbacks() -> LixhCallbacks {
    LixhCallbacks { opaque: std::ptr::null_mut(), on_video: Some(on_video), on_audio: Some(on_audio), on_event: None }
}

pub fn dock_native_surface(native_window:*mut c_void, rect:SurfaceRect) -> Result<(),String> {
    let mut slot=surface_slot().lock().map_err(|_|"surface lock poisoned".to_string())?;
    if let Some(surface)=slot.as_ref() { surface.resize(rect)?; return Ok(()); }
    let surface=NativeSurface::create(native_window)?;
    surface.resize(rect)?;
    *slot=Some(surface);
    Ok(())
}

pub fn resize_native_surface(rect:SurfaceRect) -> Result<(),String> {
    let slot=surface_slot().lock().map_err(|_|"surface lock poisoned".to_string())?;
    if let Some(surface)=slot.as_ref(){ surface.resize(rect)?; }
    Ok(())
}

pub fn destroy_native_surface() { if let Ok(mut slot)=surface_slot().lock(){ *slot=None; } }

pub struct LiveCatchBackend {
    host: PlayerHost<CorePlayerAdapter>,
}

impl LiveCatchBackend {
    pub fn new() -> Result<Self, String> {
        let core = CorePlayerAdapter::new(callbacks())
            .map_err(|e| format!("player core: {e:?}"))?;
        Ok(Self { host: PlayerHost::new(core) })
    }
    pub fn stats(&self) -> LixhStats { self.host.player().stats() }
    pub fn is_playing(&self) -> bool { self.host.is_playing() }
}

impl lixh_playback_engine::PlaybackBackend for LiveCatchBackend {
    type Telemetry = LixhStats;
    fn open(&mut self, url: &str) -> Result<(), String> {
        self.host.open(url).map_err(|e| format!("open: {e:?}"))
    }
    fn start(&mut self) -> Result<(), String> {
        self.host.start().map_err(|e| format!("start: {e:?}"))
    }
    fn stop(&mut self) -> Result<(), String> {
        self.host.stop_and_join().map_err(|e| format!("stop: {e:?}"))
    }
    fn telemetry(&self) -> Self::Telemetry { self.stats() }
    fn to_supervisor_telemetry(&self, now_ms: i64, t: &Self::Telemetry) -> lixh_stream_supervisor::PlaybackTelemetry {
        lixh_stream_supervisor::PlaybackTelemetry::from_ffmpeg(now_ms, t)
    }
}

pub type LivePlaybackEngine = PlaybackEngine<LiveCatchBackend>;

#[derive(Debug, Clone, Serialize)]
pub struct FfmpegStatus {
    pub available: bool,
    pub alive: bool,
    pub message: String,
    pub backend: String,
}

pub fn resolved_from_urls(urls: Vec<String>) -> ResolvedStream {
    ResolvedStream {
        platform: "livecatch".into(), site_url: String::new(), title: String::new(), artist: String::new(), is_live: true,
        streams: urls.into_iter().enumerate().map(|(i, url)| StreamCandidate {
            url, format: "flv".into(), media_format: "live".into(), quality: "auto".into(), bitrate: 0,
            codec: String::new(), fps: 0.0, priority: i as u32, headers_needed: false, audio_only: false,
        }).collect(), headers: None,
    }
}

pub fn create_resolved(resolved: ResolvedStream) -> Result<LivePlaybackEngine, String> {
    let backend = LiveCatchBackend::new()?;
    PlaybackEngine::from_resolved(backend, resolved)
        .map_err(|e| format!("playback engine: {e:?}"))
}

pub fn create(urls: Vec<String>) -> Result<LivePlaybackEngine, String> {
    create_resolved(resolved_from_urls(urls))
}

pub fn start(engine: &mut LivePlaybackEngine) -> Result<(), String> {
    engine.start().map(|_| ()).map_err(|e| format!("playback start: {e:?}"))
}

pub fn stop(engine: &mut LivePlaybackEngine) -> Result<(), String> {
    engine.stop().map(|_| ()).map_err(|e| format!("playback stop: {e:?}"))
}

pub fn poll(engine: &mut LivePlaybackEngine) -> Result<lixh_playback_engine::EngineState, String> {
    engine.poll().map(|_| engine.state()).map_err(|e| format!("playback poll: {e:?}"))
}

pub fn alive(engine: &LivePlaybackEngine) -> bool {
    matches!(engine.state(), EngineState::Playing) && engine.backend().is_playing()
}

pub fn stats(engine: &LivePlaybackEngine) -> LixhStats { engine.backend().stats() }

pub fn backend_name() -> &'static str { "lixh-stream-stack-0.9 / ffmpeg" }

pub fn ffmpeg_status(engine: Option<&LivePlaybackEngine>) -> FfmpegStatus {
    let alive = engine.map(alive).unwrap_or(false);
    FfmpegStatus {
        available: true,
        alive,
        message: if alive { "lixh-player-core 正在播放".into() } else { "lixh-player-core 已就绪".into() },
        backend: backend_name().into(),
    }
}

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

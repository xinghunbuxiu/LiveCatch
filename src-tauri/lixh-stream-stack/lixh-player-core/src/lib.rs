use std::ffi::{c_char,c_void,CString};use std::ptr;
#[repr(C)]pub struct LixhCallbacks{pub opaque:*mut c_void,pub on_video:Option<extern "C" fn(*mut c_void,i32,i32,i32,i64,i64,*const LixhNativeFrame)>,pub on_audio:Option<extern "C" fn(*mut c_void,i32,i32,i32,i64,*const f32,i32)>,pub on_event:Option<extern "C" fn(*mut c_void,i32,i32,*const c_char)>}
unsafe extern "C"{fn lixh_player_create(cb:*const LixhCallbacks)->*mut c_void;fn lixh_player_destroy(p:*mut c_void);fn lixh_player_open(p:*mut c_void,url:*const c_char)->i32;fn lixh_player_play(p:*mut c_void)->i32;fn lixh_player_stop(p:*mut c_void);fn lixh_player_get_stats(p:*mut c_void,out:*mut LixhStats)->i32;}
#[repr(C)]#[derive(Clone,Copy)]pub struct LixhNativeFrame{pub kind:i32,pub width:i32,pub height:i32,pub handle0:*mut c_void,pub handle1:isize,pub owner:*mut c_void}
#[repr(C)]#[derive(Default,Clone,Copy)]pub struct LixhStats{pub state:i32,pub video_frames:u64,pub audio_frames:u64,pub dropped_frames:u64,pub reconnects:u64,pub last_video_pts_ms:i64,pub last_audio_pts_ms:i64,pub input_buffer_ms:i64,pub decode_hw:i32}
pub struct Player{raw:*mut c_void}unsafe impl Send for Player{}unsafe impl Sync for Player{}
impl Player{
 pub fn new(cb:LixhCallbacks)->Result<Self,String>{let raw=unsafe{lixh_player_create(&cb)};if raw.is_null(){Err("lixh_player_create failed".into())}else{Ok(Self{raw})}}
 pub fn open(&self,url:&str)->Result<(),String>{let u=CString::new(url).map_err(|_|"url contains NUL")?;let rc=unsafe{lixh_player_open(self.raw,u.as_ptr())};if rc<0{Err(format!("open failed: {rc}"))}else{Ok(())}}
 pub fn play(&self)->Result<(),String>{let rc=unsafe{lixh_player_play(self.raw)};if rc<0{Err(format!("play failed: {rc}"))}else{Ok(())}}
 pub fn stop(&self){unsafe{lixh_player_stop(self.raw)}}pub fn is_playing(&self)->bool{self.stats().state==2}
 pub fn stats(&self)->LixhStats{let mut s=LixhStats::default();unsafe{lixh_player_get_stats(self.raw,&mut s)};s}
}
impl Drop for Player{fn drop(&mut self){unsafe{lixh_player_destroy(self.raw)}}}
pub fn callback_stub()->LixhCallbacks{LixhCallbacks{opaque:ptr::null_mut(),on_video:None,on_audio:None,on_event:None}}
pub mod runtime;pub mod surface;
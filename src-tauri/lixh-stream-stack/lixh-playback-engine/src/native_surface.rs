//! Native rendering boundary. Decoded frames never cross Tauri IPC.
use std::ffi::c_void;
#[derive(Debug,Clone,Copy)]pub struct SurfaceRect{pub x:f64,pub y:f64,pub width:f64,pub height:f64,pub device_scale:f64}
#[derive(Debug,Clone,Copy)]pub enum NativeFrameKind{Software=0,D3d11=1,VideoToolbox=2}
#[derive(Debug,Clone,Copy)]pub struct NativeFrameRef{pub kind:NativeFrameKind,pub width:i32,pub height:i32,pub handle0:*mut c_void,pub handle1:isize,pub owner:*mut c_void}
unsafe impl Send for NativeFrameRef{}
impl NativeFrameRef{pub unsafe fn from_raw(kind:i32,width:i32,height:i32,handle0:*mut c_void,handle1:isize,owner:*mut c_void)->Option<Self>{let kind=match kind{0=>NativeFrameKind::Software,1=>NativeFrameKind::D3d11,2=>NativeFrameKind::VideoToolbox,_=>return None};Some(Self{kind,width,height,handle0,handle1,owner})}}
pub trait NativeFrameSink:Send+'static{fn resize(&mut self,rect:SurfaceRect)->Result<(),String>;fn present(&mut self,frame:NativeFrameRef,pts_ms:i64)->Result<(),String>;fn flush(&mut self);}
use std::ffi::c_void;
use crate::LixhNativeFrame;
#[repr(C)]#[derive(Clone,Copy,Default)]pub struct SurfaceRect{pub x:f64,pub y:f64,pub width:f64,pub height:f64,pub device_scale:f64}

#[cfg(target_os = "windows")]
mod w {
    use super::*;
    pub fn surface_last_error() -> String { crate::surface_windows::surface_last_error() }
    pub fn surface_present_path() -> i32 { crate::surface_windows::surface_present_path() }
    pub fn surface_dcomp_stage() -> i32 { crate::surface_windows::surface_dcomp_stage() }
    pub struct NativeSurface {
        inner: std::sync::Mutex<crate::surface_windows::NativeSurface>,
    }
    unsafe impl Send for NativeSurface {}
    unsafe impl Sync for NativeSurface {}
    impl NativeSurface {
        pub fn create(native_window: *mut c_void) -> Result<Self, String> {
            crate::surface_windows::NativeSurface::create(native_window)
                .map(|inner| Self { inner: std::sync::Mutex::new(inner) })
        }
        pub fn resize(&self, rect: SurfaceRect) -> Result<(), String> {
            self.inner
                .lock()
                .map_err(|_| "surface lock poisoned".to_string())?
                .resize(rect.x, rect.y, rect.width, rect.height, rect.device_scale)
        }
        pub fn present(&self, frame: &LixhNativeFrame, pts_ms: i64) -> Result<(), String> {
            self.inner
                .lock()
                .map_err(|_| "surface lock poisoned".to_string())?
                .present(frame, pts_ms)
        }
        pub fn flush(&self) {}
    }
}

#[cfg(not(target_os = "windows"))]
mod w {
    use super::*;
    unsafe extern "C"{fn lixh_surface_create(native_window:*mut c_void,callbacks:*const c_void)->*mut c_void;fn lixh_surface_last_error()->*const i8;fn lixh_surface_present_path()->i32;fn lixh_surface_dcomp_stage()->i32;fn lixh_surface_destroy(surface:*mut c_void);fn lixh_surface_resize(surface:*mut c_void,rect:SurfaceRect)->i32;fn lixh_surface_present(surface:*mut c_void,frame:*const LixhNativeFrame,pts_ms:i64)->i32;fn lixh_surface_flush(surface:*mut c_void);}
    pub fn surface_last_error()->String{unsafe{let p=lixh_surface_last_error();if p.is_null(){return String::new();}std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()}}
    pub fn surface_present_path()->i32{unsafe{lixh_surface_present_path()}}
    pub fn surface_dcomp_stage()->i32{unsafe{lixh_surface_dcomp_stage()}}
    pub struct NativeSurface{raw:*mut c_void}unsafe impl Send for NativeSurface{}unsafe impl Sync for NativeSurface{}
    impl NativeSurface{pub fn create(native_window:*mut c_void)->Result<Self,String>{let raw=unsafe{lixh_surface_create(native_window,std::ptr::null())};if raw.is_null(){let detail=surface_last_error();if detail.is_empty(){Err("lixh native surface create failed".into())}else{Err(format!("lixh native surface create failed: {detail}"))}}else{Ok(Self{raw})}}pub fn resize(&self,rect:SurfaceRect)->Result<(),String>{let rc=unsafe{lixh_surface_resize(self.raw,rect)};if rc==0{Ok(())}else{Err(format!("surface resize failed: {rc}"))}}pub fn present(&self,frame:&LixhNativeFrame,pts_ms:i64)->Result<(),String>{let rc=unsafe{lixh_surface_present(self.raw,frame,pts_ms)};if rc==0{Ok(())}else{Err(format!("surface present failed: {rc}"))}}pub fn flush(&self){unsafe{lixh_surface_flush(self.raw)}}}
    impl Drop for NativeSurface{fn drop(&mut self){unsafe{lixh_surface_destroy(self.raw)}}}
}

pub use w::*;

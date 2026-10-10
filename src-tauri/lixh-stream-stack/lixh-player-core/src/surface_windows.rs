// Windows native video surface, implemented directly in Rust with the
// `windows` crate (no C++ bridge). Mirrors the battle-tested behavior of the
// previous C++ implementation:
//
// - child HWND hosting the picture ABOVE WebView2 (HWND_TOP). WebView2 already
//   owns a DirectComposition target on the Tauri parent HWND, so binding DComp
//   to the parent fails or stays buried — same "black hole, audio only" failure
//   mode the macOS layer fixes with zPosition=1000.
// - D3D11 device (hardware, then WARP) for DirectComposition on the child HWND
// - DirectComposition NV12 overlay: GPU YUV->RGB + aspect-fit scale, DWM
//   vsync, tear-free, RDP friendly.
// - GDI StretchDIBits fallback when DComp is unavailable (still visible via
//   HWND_TOP; HTTRANSPARENT keeps clicks reaching the page).
//
// Diagnostics mirror the old C ABI: last_error(), present_path()
// (0 none / 1 DComp / 2 GDI / 3 D3D11), dcomp_stage() (0 untried / 1 ok /
// negative = failure step).
#![allow(clippy::too_many_arguments)]

use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering::Relaxed};

use windows::core::{w, IUnknown, Interface};
#[cfg(target_os = "windows")]
use windows_numerics::Matrix3x2;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, POINT, WPARAM, HINSTANCE, HMODULE};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Resource, ID3D11Texture2D,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
};
use windows::Win32::Graphics::DirectComposition::{
    DCompositionCreateDevice, IDCompositionDevice, IDCompositionSurface, IDCompositionTarget,
    IDCompositionVisual, IDCompositionMatrixTransform,
};
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGISurface, DXGI_MAP_WRITE, DXGI_MAPPED_RECT};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_ALPHA_MODE_IGNORE};
use windows::Win32::Graphics::Gdi::{
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CreateCompatibleBitmap, CreateCompatibleDC,
    DeleteDC, DeleteObject, FillRect, GetDC, GetStockObject, BLACK_BRUSH, ReleaseDC,
    SelectObject, SetDIBitsToDevice, SetStretchBltMode, StretchBlt, DIB_RGB_COLORS,
    HALFTONE, SRCCOPY, HDC, HGDIOBJ,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, EnumChildWindows, GetClientRect,
    GetWindowLongW, RegisterClassW, SetWindowLongW, SetWindowPos, HWND_TOP,
    GWL_STYLE, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOREDRAW,
    SWP_SHOWWINDOW, WM_ERASEBKGND, WM_NCHITTEST, WS_CHILD, WS_CLIPCHILDREN,
    WS_CLIPSIBLINGS, WS_VISIBLE, WS_EX_NOACTIVATE, WNDCLASSW, HTTRANSPARENT,
};

use crate::LixhNativeFrame;

// FFmpeg values (verified against sdk/windows-x64 headers).
const AV_PIX_FMT_YUV420P: i32 = 0;
const AV_PIX_FMT_YUVJ420P: i32 = 12;
const AV_PIX_FMT_NV12: i32 = 23;
const AV_PIX_FMT_NV21: i32 = 24;
const LIXH_VIDEO_SOFTWARE: i32 = 0;

/// Minimal AVFrame view: only the fields we read (offsets verified).
#[repr(C)]
struct AvFrameLite {
    data: [*mut u8; 8],
    linesize: [i32; 8],
    _extended_data: *mut u8,
    width: i32,
    height: i32,
    _nb_samples: i32,
    format: i32,
}

static PRESENT_PATH: AtomicI32 = AtomicI32::new(0);
static DCOMP_STAGE: AtomicI32 = AtomicI32::new(0);
static LAST_ERROR_MSG: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

fn set_err(msg: &str) {
    if let Ok(mut s) = LAST_ERROR_MSG.lock() {
        s.clear();
        s.push_str(msg);
    }
}

pub fn surface_last_error() -> String {
    LAST_ERROR_MSG.lock().map(|s| s.clone()).unwrap_or_default()
}
pub fn surface_present_path() -> i32 {
    PRESENT_PATH.load(Relaxed)
}
pub fn surface_dcomp_stage() -> i32 {
    DCOMP_STAGE.load(Relaxed)
}

unsafe extern "system" fn host_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_ERASEBKGND {
        unsafe {
            let hdc = HDC(wp.0 as *mut c_void);
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            FillRect(hdc, &rc, HBRUSH(GetStockObject(BLACK_BRUSH).0));
        }
        return LRESULT(1);
    }
    if msg == WM_NCHITTEST {
        return LRESULT(HTTRANSPARENT as isize);
    }
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}

use windows::Win32::Graphics::Gdi::HBRUSH;

fn ensure_host_class() -> bool {
    static ONCE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ONCE.get_or_init(|| unsafe {
        let instance = HINSTANCE(
            GetModuleHandleW(None).map(|h| h.0).unwrap_or(ptr::null_mut()),
        );
        let wc = WNDCLASSW {
            lpfnWndProc: Some(host_proc),
            hInstance: instance,
            lpszClassName: w!("LixhPlayerNativeSurface"),
            ..Default::default()
        };
        RegisterClassW(&wc) != 0
    })
}

/// WebView2 (WRY_WEBVIEW / Chrome_WidgetWin_*) and our surface are sibling
/// child HWNDs. Without WS_CLIPSIBLINGS on *both*, Win32 z-order is undefined
/// and WebView2 typically wins — host is "topmost" but paints nothing (black).
unsafe fn ensure_clip_siblings(parent: HWND) {
    unsafe extern "system" fn each(child: HWND, _lp: LPARAM) -> windows::core::BOOL {
        unsafe {
            let style = GetWindowLongW(child, GWL_STYLE);
            if style & WS_CLIPSIBLINGS.0 as i32 == 0 {
                SetWindowLongW(child, GWL_STYLE, style | WS_CLIPSIBLINGS.0 as i32);
                let _ = SetWindowPos(
                    child,
                    None,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_NOREDRAW,
                );
            }
        }
        windows::core::BOOL(1)
    }
    unsafe {
        let _ = EnumChildWindows(Some(parent), Some(each), LPARAM(0));
    }
}

fn raise_surface(hwnd: HWND) {
    unsafe {
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOP),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
    }
}

pub struct NativeSurface {
    _parent: HWND,
    hwnd: HWND,
    dev: Option<ID3D11Device>,
    _ctx: Option<ID3D11DeviceContext>,
    dcomp: Option<IDCompositionDevice>,
    dtarget: Option<IDCompositionTarget>,
    dvisual: Option<IDCompositionVisual>,
    dtransform: Option<IDCompositionMatrixTransform>,
    dsurf: Option<IDCompositionSurface>,
    dsurf_w: u32,
    dsurf_h: u32,
    dcomp_ok: bool,
    w: u32,
    h: u32,
    ox: i32,
    oy: i32,
    rgb: Vec<u8>,
    rgb_w: u32,
    rgb_h: u32,
    uv_tmp: Vec<u8>,
    uv_tmp_w: u32,
    uv_tmp_h: u32,
    frames: u64,
}

unsafe impl Send for NativeSurface {}
unsafe impl Sync for NativeSurface {}

fn d3d_device(driver_hardware: bool) -> Option<(ID3D11Device, ID3D11DeviceContext)> {
    unsafe {
        let mut dev: Option<ID3D11Device> = None;
        let mut ctx: Option<ID3D11DeviceContext> = None;
        let driver = if driver_hardware {
            D3D_DRIVER_TYPE_HARDWARE
        } else {
            D3D_DRIVER_TYPE_WARP
        };
        let adapter: Option<&windows::Win32::Graphics::Dxgi::IDXGIAdapter> = None;
        let ok = D3D11CreateDevice(
            adapter,
            driver,
            HMODULE(std::ptr::null_mut()),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut dev),
            None,
            Some(&mut ctx),
        )
        .is_ok();
        if ok {
            match (dev, ctx) {
                (Some(d), Some(c)) => Some((d, c)),
                _ => None,
            }
        } else {
            None
        }
    }
}

impl NativeSurface {
    pub fn create(native_window: *mut c_void) -> Result<Self, String> {
        if native_window.is_null() {
            set_err("null parent HWND");
            return Err("lixh native surface create failed: null parent HWND".into());
        }
        if !ensure_host_class() {
            set_err("RegisterClassW failed");
            return Err("lixh native surface create failed: RegisterClassW failed".into());
        }
        let parent = HWND(native_window);
        let hwnd = unsafe {
            let instance = HINSTANCE(
                GetModuleHandleW(None).map(|h| h.0).unwrap_or(ptr::null_mut()),
            );
            CreateWindowExW(
                WS_EX_NOACTIVATE,
                w!("LixhPlayerNativeSurface"),
                w!(""),
                WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                0,
                0,
                1,
                1,
                Some(parent),
                None,
                Some(instance),
                None,
            )
            .unwrap_or_default()
        };
        if hwnd.is_invalid() {
            set_err("CreateWindowExW failed");
            return Err("lixh native surface create failed: CreateWindowExW failed".into());
        }
        unsafe { ensure_clip_siblings(parent); }
        raise_surface(hwnd);
        // Device for DirectComposition (video interfaces not required).
        let mut dev = None;
        let mut ctx = None;
        if let Some((d, c)) = d3d_device(true) {
            dev = Some(d);
            ctx = Some(c);
        } else if let Some((d, c)) = d3d_device(false) {
            dev = Some(d);
            ctx = Some(c);
        }
        if dev.is_none() {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            set_err("D3D11CreateDevice failed hw+warp");
            return Err("lixh native surface create failed: D3D11CreateDevice failed hw+warp".into());
        }
        set_err("");
        Ok(Self {
            _parent: parent,
            hwnd,
            dev,
            _ctx: ctx,
            dcomp: None,
            dtarget: None,
            dvisual: None,
            dtransform: None,
            dsurf: None,
            dsurf_w: 0,
            dsurf_h: 0,
            dcomp_ok: false,
            w: 1,
            h: 1,
            ox: 0,
            oy: 0,
            rgb: Vec::new(),
            rgb_w: 0,
            rgb_h: 0,
            uv_tmp: Vec::new(),
            uv_tmp_w: 0,
            uv_tmp_h: 0,
            frames: 0,
        })
    }

    pub fn resize(&mut self, x: f64, y: f64, w: f64, h: f64, scale: f64) -> Result<(), String> {
        let scale = if scale > 0.0 { scale } else { 1.0 };
        let (x, y, w, h) = (
            (x * scale).round() as i32,
            (y * scale).round() as i32,
            (w * scale).round().max(1.0) as u32,
            (h * scale).round().max(1.0) as u32,
        );
        if self.w == w && self.h == h && self.ox == x && self.oy == y {
            return Ok(());
        }
        unsafe {
            ensure_clip_siblings(self._parent);
            // Stay above the WebView2 sibling so GDI paints are actually visible.
            let _ = SetWindowPos(
                self.hwnd,
                Some(HWND_TOP),
                x,
                y,
                w as i32,
                h as i32,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
        }
        self.ox = x;
        self.oy = y;
        self.w = w;
        self.h = h;
        Ok(())
    }

    fn setup_dcomp(&mut self) -> bool {
            if self.dcomp_ok {
            DCOMP_STAGE.store(1, Relaxed);
            return true;
        }
        unsafe {
            let dev = match self.dev.as_ref() {
                Some(d) => d,
                None => {
                    DCOMP_STAGE.store(-1, Relaxed);
                    return false;
                }
            };
            let dxgi: Result<IDXGIDevice, _> = dev.cast();
            let dxgi = match dxgi {
                Ok(d) => d,
                Err(_) => {
                    DCOMP_STAGE.store(-1, Relaxed);
                    return false;
                }
            };
            let dcomp: IDCompositionDevice = match DCompositionCreateDevice(Some(&dxgi)) {
                Ok(d) => d,
                Err(_) => {
                    DCOMP_STAGE.store(-2, Relaxed);
                    return false;
                }
            };
            // Bind DComp to the child surface HWND — never the Tauri parent.
            // WebView2 already creates a composition target on the parent; a
            // second CreateTargetForHwnd(parent) fails (stage -3) or stays
            // under the page, which is the video-mode black screen.
            let target = match dcomp.CreateTargetForHwnd(self.hwnd, true) {
                Ok(t) => t,
                Err(_) => {
                    DCOMP_STAGE.store(-3, Relaxed);
                    return false;
                }
            };
            let visual = match dcomp.CreateVisual() {
                Ok(v) => v,
                Err(_) => {
                    DCOMP_STAGE.store(-4, Relaxed);
                    return false;
                }
            };
            if target.SetRoot(&visual).is_err() {
                DCOMP_STAGE.store(-5, Relaxed);
                return false;
            }
            self.dcomp = Some(dcomp);
            self.dtarget = Some(target);
            self.dvisual = Some(visual);
            self.dcomp_ok = true;
            DCOMP_STAGE.store(1, Relaxed);
            true
        }
    }

    fn uv_plane(&mut self, av: &AvFrameLite) -> Option<(*const u8, i32, *const u8, i32)> {
        let w = av.width as u32;
        let h = av.height as u32;
        let chw = (w + 1) / 2;
        let chh = (h + 1) / 2;
        unsafe {
            if av.format == AV_PIX_FMT_NV12 {
                if av.data[1].is_null() {
                    return None;
                }
                Some((av.data[0] as *const u8, av.linesize[0], av.data[1] as *const u8, av.linesize[1]))
            } else {
                if self.uv_tmp_w != chw || self.uv_tmp_h != chh {
                    self.uv_tmp = vec![0u8; (chw as usize) * 2 * (chh as usize)];
                    self.uv_tmp_w = chw;
                    self.uv_tmp_h = chh;
                }
                let dst = self.uv_tmp.as_mut_ptr();
                if av.format == AV_PIX_FMT_NV21 {
                    if av.data[1].is_null() {
                        return None;
                    }
                    for y in 0..chh {
                        let src = av.data[1].add(y as usize * av.linesize[1] as usize);
                        let row = dst.add(y as usize * chw as usize * 2);
                        for x in 0..chw {
                            *row.add(x as usize * 2) = *src.add(x as usize * 2 + 1);
                            *row.add(x as usize * 2 + 1) = *src.add(x as usize * 2);
                        }
                    }
                } else if av.format == AV_PIX_FMT_YUV420P || av.format == AV_PIX_FMT_YUVJ420P {
                    if av.data[1].is_null() || av.data[2].is_null() {
                        return None;
                    }
                    for y in 0..chh {
                        let su = av.data[1].add(y as usize * av.linesize[1] as usize);
                        let sv = av.data[2].add(y as usize * av.linesize[2] as usize);
                        let row = dst.add(y as usize * chw as usize * 2);
                        for x in 0..chw {
                            *row.add(x as usize * 2) = *su.add(x as usize);
                            *row.add(x as usize * 2 + 1) = *sv.add(x as usize);
                        }
                    }
                } else {
                    return None;
                }
                Some((
                    av.data[0] as *const u8,
                    av.linesize[0],
                    dst as *const u8,
                    chw as i32 * 2,
                ))
            }
        }
    }

    #[inline]
    fn clamp8(v: i32) -> u8 {
        v.clamp(0, 255) as u8
    }

    /// NV12 (with strides) -> RGB32. BT.601 limited-range integer math.
    fn nv12_to_rgb32(
        y_plane: *const u8,
        y_stride: i32,
        uv_plane: *const u8,
        uv_stride: i32,
        dst: *mut u8,
        w: u32,
        h: u32,
    ) {
        unsafe {
            for y in 0..h {
                let yp = y_plane.add(y as usize * y_stride as usize);
                let uvp = uv_plane.add((y / 2) as usize * uv_stride as usize);
                let dp = dst.add(y as usize * w as usize * 4);
                for x in 0..w {
                    let c = *yp.add(x as usize) as i32 - 16;
                    let d = *uvp.add((x / 2) as usize * 2) as i32 - 128;
                    let e = *uvp.add((x / 2) as usize * 2 + 1) as i32 - 128;
                    let r = (298 * c + 409 * e + 128) >> 8;
                    let g = (298 * c - 100 * d - 208 * e + 128) >> 8;
                    let b = (298 * c + 516 * d + 128) >> 8;
                    *dp.add(x as usize * 4) = Self::clamp8(b);
                    *dp.add(x as usize * 4 + 1) = Self::clamp8(g);
                    *dp.add(x as usize * 4 + 2) = Self::clamp8(r);
                    *dp.add(x as usize * 4 + 3) = 255;
                }
            }
        }
    }

    fn apply_transform(&mut self, source_w: u32, source_h: u32) -> Result<(), i32> {
        let dcomp = self.dcomp.as_ref().ok_or(-11)?;
        let visual = self.dvisual.as_ref().ok_or(-11)?;
        let mut rc = RECT::default();
        unsafe { let _ = GetClientRect(self.hwnd, &mut rc); }
        let mut dw = rc.right - rc.left;
        let mut dh = rc.bottom - rc.top;
        if dw <= 0 || dh <= 0 {
            dw = self.w as i32;
            dh = self.h as i32;
        }
        let mut sc = 1.0f32;
        let mut dx = 0.0f32;
        let mut dy = 0.0f32;
        if dw > 0 && dh > 0 && source_w > 0 && source_h > 0 {
            sc = dw as f32 / source_w as f32;
            sc = sc.min(dh as f32 / source_h as f32);
            dx = (dw as f32 - source_w as f32 * sc) / 2.0;
            dy = (dh as f32 - source_h as f32 * sc) / 2.0;
        }
        if self.dtransform.is_none() {
            self.dtransform = Some(unsafe { dcomp.CreateMatrixTransform() }.map_err(|_| -11)?);
        }
        let transform = self.dtransform.as_ref().ok_or(-11)?;
        // DComp target is the child HWND: offsets are client-local (letterbox
        // only). Parent dock position is handled by SetWindowPos on resize.
        let matrix = Matrix3x2 {
            M11: sc, M12: 0.0, M21: 0.0, M22: sc,
            M31: dx, M32: dy,
        };
        unsafe {
            transform.SetMatrix(&matrix).map_err(|_| -11)?;
            visual.SetTransform(transform).map_err(|_| -11)?;
        }
        Ok(())
    }

    fn present_d3d11(&mut self, frame: &LixhNativeFrame) -> Result<(), i32> {
        if frame.handle0.is_null() { return Err(-2); }
        unsafe {
            let source = std::mem::ManuallyDrop::new(ID3D11Texture2D::from_raw(frame.handle0));
            let source_resource: ID3D11Resource = source.cast().map_err(|_| -12)?;
            let source_device = source_resource.GetDevice().map_err(|_| -12)?;

            let replace_device = self.dev.as_ref()
                .map(|device| device.as_raw() != source_device.as_raw())
                .unwrap_or(true);
            if replace_device {
                if frame.owner.is_null() { return Err(-12); }
                let context = std::mem::ManuallyDrop::new(ID3D11DeviceContext::from_raw(frame.owner));
                self.dev = Some(source_device);
                self._ctx = Some((*context).clone());
                self.dcomp = None;
                self.dtarget = None;
                self.dvisual = None;
                self.dtransform = None;
                self.dsurf = None;
                self.dsurf_w = 0;
                self.dsurf_h = 0;
                self.dcomp_ok = false;
            }
            if !self.setup_dcomp() { return Err(-11); }

            let mut desc = std::mem::zeroed();
            source.GetDesc(&mut desc);
            let w = frame.width.max(1) as u32;
            let h = frame.height.max(1) as u32;
            if self.dsurf.is_none() || self.dsurf_w != w || self.dsurf_h != h {
                let dcomp = self.dcomp.as_ref().ok_or(-11)?;
                let visual = self.dvisual.as_ref().ok_or(-11)?;
                let surface = dcomp.CreateSurface(w, h, desc.Format, DXGI_ALPHA_MODE_IGNORE).map_err(|_| -11)?;
                visual.SetContent(&surface.cast::<IUnknown>().map_err(|_| -11)?).map_err(|_| -11)?;
                self.dsurf = Some(surface);
                self.dsurf_w = w;
                self.dsurf_h = h;
            }
            let surface = self.dsurf.as_ref().ok_or(-11)?;
            let update = RECT { left: 0, top: 0, right: w as i32, bottom: h as i32 };
            let mut offset = POINT::default();
            let destination: ID3D11Texture2D = surface.BeginDraw(Some(&update as *const RECT), &mut offset).map_err(|_| -11)?;
            let destination_resource: ID3D11Resource = destination.cast().map_err(|_| -12)?;
            let context = self._ctx.as_ref().ok_or(-12)?;
            let source_subresource = frame.handle1.max(0) as u32;
            context.CopySubresourceRegion(&destination_resource, 0, 0, 0, 0, &source_resource, source_subresource, None);
            surface.EndDraw().map_err(|_| -11)?;
            self.apply_transform(w, h)?;
            self.dcomp.as_ref().ok_or(-11)?.Commit().map_err(|_| -11)?;
            PRESENT_PATH.store(3, Relaxed);
            Ok(())
        }
    }

    fn present_dcomp(&mut self, av: &AvFrameLite) -> Result<(), i32> {
        if !self.setup_dcomp() {
            return Err(-11);
        }
        let w = av.width as u32;
        let h = av.height as u32;
        let ok_fmt = matches!(av.format, AV_PIX_FMT_NV12 | AV_PIX_FMT_NV21 | AV_PIX_FMT_YUV420P | AV_PIX_FMT_YUVJ420P);
        if !ok_fmt || av.data[0].is_null() {
            return Err(-9);
        }
        unsafe {
            // Resolve planes first: uv_plane() takes &mut (may grow the
            // scratch cache), so it must run before any other self borrows.
            let (_y_plane, _ys, uv_plane, uv_stride) = self.uv_plane(av).ok_or(-9)?;
            let y_stride = av.linesize[0];
            let dcomp = self.dcomp.as_ref().ok_or(-11)?;
            let visual = self.dvisual.as_ref().ok_or(-11)?;
            if self.dsurf.is_none() || self.dsurf_w != w || self.dsurf_h != h {
                self.dsurf = None;
                let s = dcomp
                    .CreateSurface(w, h, DXGI_FORMAT_NV12, DXGI_ALPHA_MODE_IGNORE)
                    .map_err(|_| -11)?;
                visual.SetContent(&s.cast::<IUnknown>().map_err(|_| -11)?).map_err(|_| -11)?;
                self.dsurf = Some(s);
                self.dsurf_w = w;
                self.dsurf_h = h;
            }
            let surf = self.dsurf.as_ref().ok_or(-11)?;
            let upd = RECT { left: 0, top: 0, right: w as i32, bottom: h as i32 };
            let mut off = POINT { x: 0, y: 0 };
            let dc_obj: IDXGISurface = surf
                .BeginDraw(Some(&upd as *const RECT), &mut off)
                .map_err(|_| -11)?;
            let mut map = DXGI_MAPPED_RECT::default();
            dc_obj.Map(&mut map, DXGI_MAP_WRITE).map_err(|_| -11)?;
            {
                let pitch = map.Pitch as i32;
                let bits = map.pBits as *mut u8;
                let y_dst = bits;
                let uv_dst = bits.add(pitch as usize * h as usize);
                for y in 0..h {
                    ptr::copy_nonoverlapping(
                        av.data[0].add(y as usize * y_stride as usize),
                        y_dst.add(y as usize * pitch as usize),
                        w as usize,
                    );
                }
                let chw = (w + 1) / 2;
                let chh = (h + 1) / 2;
                for y in 0..chh {
                    let row = uv_dst.add(y as usize * pitch as usize);
                    ptr::copy_nonoverlapping(
                        uv_plane.add(y as usize * uv_stride as usize),
                        row,
                        chw as usize * 2,
                    );
                }
                let _ = dc_obj.Unmap();
            }
            surf.EndDraw().map_err(|_| -11)?;
            self.apply_transform(w, h)?;
            self.dcomp.as_ref().ok_or(-11)?.Commit().map_err(|_| -11)?;
            PRESENT_PATH.store(1, Relaxed);
            Ok(())
        }
    }

    fn present_gdi(&mut self, av: &AvFrameLite) -> Result<(), i32> {
        let w = av.width as u32;
        let h = av.height as u32;
        // Buffers first (uv cache is dropped by the clear, so resolve planes after).
        if self.rgb_w != w || self.rgb_h != h || self.rgb.is_empty() {
            self.rgb = vec![0u8; w as usize * h as usize * 4];
            self.rgb_w = w;
            self.rgb_h = h;
            self.uv_tmp.clear();
            self.uv_tmp_w = 0;
            self.uv_tmp_h = 0;
        }
        let (y_plane, y_stride, uv_plane, uv_stride) = self.uv_plane(av).ok_or(-9)?;
        Self::nv12_to_rgb32(y_plane, y_stride, uv_plane, uv_stride, self.rgb.as_mut_ptr(), w, h);
        unsafe {
            let hdc = GetDC(Some(self.hwnd));
            if hdc.is_invalid() {
                return Err(-10);
            }
            let mut rc = RECT::default();
            let _ = GetClientRect(self.hwnd, &mut rc);
            let mut dw = rc.right - rc.left;
            let mut dh = rc.bottom - rc.top;
            if dw <= 0 || dh <= 0 {
                dw = w as i32;
                dh = h as i32;
            }
            let mut dw2 = dw;
            let mut dh2 = dh;
            let mut dx = 0;
            let mut dy = 0;
            if w > 0 && h > 0 {
                let mut sc = dw as f64 / w as f64;
                let sc_h = dh as f64 / h as f64;
                if sc_h < sc {
                    sc = sc_h;
                }
                dw2 = (w as f64 * sc) as i32;
                dh2 = (h as f64 * sc) as i32;
                dx = (dw - dw2) / 2;
                dy = (dh - dh2) / 2;
            }
            FillRect(hdc, &rc, HBRUSH(GetStockObject(BLACK_BRUSH).0));
            let mut bmi: BITMAPINFO = std::mem::zeroed();
            bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
            bmi.bmiHeader.biWidth = w as i32;
            bmi.bmiHeader.biHeight = -(h as i32);
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB.0 as u32;
            let bits = self.rgb.as_ptr() as *const c_void;
            let ok = if dw2 == w as i32 && dh2 == h as i32 {
                SetDIBitsToDevice(hdc, dx, dy, dw2 as u32, dh2 as u32, 0, 0, 0, h, bits, &bmi, DIB_RGB_COLORS)
            } else {
                let mem = CreateCompatibleDC(Some(hdc));
                if mem.is_invalid() {
                    let _ = ReleaseDC(Some(self.hwnd), hdc);
                    return Err(-10);
                }
                let bmp = CreateCompatibleBitmap(hdc, w as i32, h as i32);
                let old = SelectObject(mem, HGDIOBJ(bmp.0));
                SetDIBitsToDevice(mem, 0, 0, w, h, 0, 0, 0, h, bits, &bmi, DIB_RGB_COLORS);
                SetStretchBltMode(hdc, HALFTONE);
                let r = StretchBlt(hdc, dx, dy, dw2, dh2, Some(mem), 0, 0, w as i32, h as i32, SRCCOPY);
                let _ = SelectObject(mem, old);
                let _ = DeleteObject(HGDIOBJ(bmp.0));
                let _ = DeleteDC(mem);
                r.0
            };
            let _ = ReleaseDC(Some(self.hwnd), hdc);
            if ok != 0 {
                PRESENT_PATH.store(2, Relaxed);
                Ok(())
            } else {
                Err(-10)
            }
        }
    }

    pub fn present(&mut self, frame: &LixhNativeFrame, pts_ms: i64) -> Result<(), String> {
        self.frames += 1;
        let f = self.frames;
        if f % 120 == 1 {
            unsafe { ensure_clip_siblings(self._parent); }
            raise_surface(self.hwnd);
        }
        if frame.handle0.is_null() {
            return Err("surface present failed: -2".into());
        }
        // Sibling-above-WebView2: DComp-on-child often Commit()s successfully
        // but never appears (DWM/WebView2 composition wins). Paint the HWND
        // itself with GDI so HWND_TOP + WS_CLIPSIBLINGS can show the picture.
        // Returning -11 for D3D11 forces the player to download + software path.
        if frame.kind == 1 {
            let _ = pts_ms;
            return Err("surface present failed: -11".into());
        }
        if frame.kind != LIXH_VIDEO_SOFTWARE {
            return Err("surface present failed: -2".into());
        }
        let av = unsafe { &*(frame.handle0 as *const AvFrameLite) };
        if av.width <= 0 || av.height <= 0 || av.data[0].is_null() {
            return Err("surface present failed: -9".into());
        }
        let _ = pts_ms;
        match self.present_gdi(av) {
            Ok(()) => Ok(()),
            Err(gdi_err) => match self.present_dcomp(av) {
                Ok(()) => Ok(()),
                Err(_) => Err(format!("surface present failed: {gdi_err}")),
            },
        }
    }
}

impl Drop for NativeSurface {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.hwnd);
        }
    }
}
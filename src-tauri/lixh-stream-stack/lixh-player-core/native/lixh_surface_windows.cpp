#ifdef _WIN32
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3d11_1.h>
#include <algorithm>
#include <cmath>
#include "lixh_surface.h"
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

struct LixhWinSurface {
    HWND parent{};
    HWND hwnd{};
    ID3D11Device *dev=nullptr; ID3D11DeviceContext *ctx=nullptr;
    IDXGISwapChain1 *swap=nullptr; ID3D11VideoDevice *video=nullptr; ID3D11VideoContext *vctx=nullptr;
    ID3D11VideoProcessorEnumerator *enumerator=nullptr; ID3D11VideoProcessor *processor=nullptr;
    LixhSurfaceCallbacks cb{}; UINT w=1,h=1; UINT physical_x=0,physical_y=0;
};

static void rel(IUnknown *p){if(p)p->Release();}
static void clear_processor(LixhWinSurface*s){rel(s->processor);s->processor=nullptr;rel(s->enumerator);s->enumerator=nullptr;}

static LRESULT CALLBACK lixh_host_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp){
    if(msg==WM_ERASEBKGND) return 1;
    if(msg==WM_NCHITTEST) return HTTRANSPARENT;
    return DefWindowProcW(hwnd,msg,wp,lp);
}

static ATOM ensure_host_class(){
    static ATOM atom=[](){
        WNDCLASSW wc{};
        wc.lpfnWndProc=lixh_host_proc;
        wc.hInstance=GetModuleHandleW(nullptr);
        wc.lpszClassName=L"LixhPlayerNativeSurface";
        wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
        return RegisterClassW(&wc);
    }();
    return atom;
}

static bool setup_processor(LixhWinSurface*s,UINT iw,UINT ih){
    clear_processor(s);
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC c{};
    c.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    c.InputWidth=iw;c.InputHeight=ih;c.OutputWidth=s->w;c.OutputHeight=s->h;
    c.OutputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    if(FAILED(s->video->CreateVideoProcessorEnumerator(&c,&s->enumerator)))return false;
    if(FAILED(s->video->CreateVideoProcessor(s->enumerator,0,&s->processor)))return false;
    return true;
}

void *lixh_surface_create(void *native_window,const LixhSurfaceCallbacks *cb){
    HWND parent=(HWND)native_window;
    if(!parent || !ensure_host_class()) return nullptr;

    auto*s=new LixhWinSurface();
    s->parent=parent;
    if(cb)s->cb=*cb;

    s->hwnd=CreateWindowExW(
        WS_EX_NOACTIVATE,L"LixhPlayerNativeSurface",L"",
        WS_CHILD|WS_VISIBLE|WS_CLIPSIBLINGS|WS_CLIPCHILDREN,
        0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
    if(!s->hwnd){delete s;return nullptr;}

    UINT flags=D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL fl;
    if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,flags,nullptr,0,D3D11_SDK_VERSION,&s->dev,&fl,&s->ctx))){
        DestroyWindow(s->hwnd); delete s; return nullptr;
    }
    if(FAILED(s->dev->QueryInterface(IID_PPV_ARGS(&s->video))) || FAILED(s->ctx->QueryInterface(IID_PPV_ARGS(&s->vctx)))){
        rel(s->vctx);rel(s->video);rel(s->ctx);rel(s->dev);DestroyWindow(s->hwnd);delete s;return nullptr;
    }

    IDXGIDevice*gd=nullptr;IDXGIAdapter*ad=nullptr;IDXGIFactory2*fac=nullptr;
    if(FAILED(s->dev->QueryInterface(IID_PPV_ARGS(&gd))) || FAILED(gd->GetAdapter(&ad)) || FAILED(ad->GetParent(IID_PPV_ARGS(&fac)))){
        rel(fac);rel(ad);rel(gd);rel(s->vctx);rel(s->video);rel(s->ctx);rel(s->dev);DestroyWindow(s->hwnd);delete s;return nullptr;
    }

    DXGI_SWAP_CHAIN_DESC1 d{};
    d.Width=1;d.Height=1;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.BufferCount=2;
    d.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;d.SampleDesc.Count=1;d.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
    HRESULT hr=fac->CreateSwapChainForHwnd(s->dev,s->hwnd,&d,nullptr,nullptr,&s->swap);
    rel(fac);rel(ad);rel(gd);
    if(FAILED(hr)){
        rel(s->vctx);rel(s->video);rel(s->ctx);rel(s->dev);DestroyWindow(s->hwnd);delete s;return nullptr;
    }
    if(s->cb.on_ready)s->cb.on_ready(s->cb.opaque,s);
    return s;
}

int lixh_surface_resize(void*surface,LixhSurfaceRect rect){
    auto*s=(LixhWinSurface*)surface;
    if(!s||!s->swap||!s->hwnd)return-1;
    const double scale=rect.device_scale>0.0?rect.device_scale:1.0;
    int x=(int)llround(rect.x*scale), y=(int)llround(rect.y*scale);
    int w=std::max(1,(int)llround(rect.width*scale)), h=std::max(1,(int)llround(rect.height*scale));
    const bool same_geometry = s->w==(UINT)w && s->h==(UINT)h &&
        s->physical_x==(UINT)x && s->physical_y==(UINT)y;
    if (same_geometry) return 0;
    SetWindowPos(s->hwnd,HWND_TOP,x,y,w,h,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    const bool same_size = s->w==(UINT)w && s->h==(UINT)h;
    s->physical_x=(UINT)x; s->physical_y=(UINT)y;
    if (same_size) return 0;
    s->w=(UINT)w;s->h=(UINT)h;
    HRESULT hr=s->swap->ResizeBuffers(0,s->w,s->h,DXGI_FORMAT_UNKNOWN,0);
    clear_processor(s);
    return SUCCEEDED(hr)?0:-2;
}

int lixh_surface_present(void*surface,const LixhNativeFrame*frame,int64_t pts){
    auto*s=(LixhWinSurface*)surface;
    if(!s||!frame||frame->kind!=LIXH_VIDEO_D3D11||!frame->handle0||!s->swap)return-2;
    auto*tex=(ID3D11Texture2D*)frame->handle0;D3D11_TEXTURE2D_DESC td{};tex->GetDesc(&td);
    if(td.Format!=DXGI_FORMAT_NV12)return-3;
    if(!s->processor && !setup_processor(s,td.Width,td.Height))return-4;
    ID3D11Resource*back=nullptr;HRESULT hr=s->swap->GetBuffer(0,IID_PPV_ARGS(&back));if(FAILED(hr))return-5;
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC id{};id.ViewDimension=D3D11_VPIV_DIMENSION_TEXTURE2D;id.Texture2D.MipSlice=0;id.Texture2D.ArraySlice=(UINT)frame->handle1;
    ID3D11VideoProcessorInputView*iv=nullptr;hr=s->video->CreateVideoProcessorInputView(tex,s->enumerator,&id,&iv);if(FAILED(hr)){rel(back);return-6;}
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC od{};od.ViewDimension=D3D11_VPOV_DIMENSION_TEXTURE2D;od.Texture2D.MipSlice=0;ID3D11VideoProcessorOutputView*ov=nullptr;hr=s->video->CreateVideoProcessorOutputView(back,s->enumerator,&od,&ov);if(FAILED(hr)){rel(iv);rel(back);return-7;}
    D3D11_VIDEO_PROCESSOR_STREAM st{};st.Enable=TRUE;st.pInputSurface=iv;
    RECT src{0,0,(LONG)td.Width,(LONG)td.Height};RECT dst{0,0,(LONG)s->w,(LONG)s->h};
    s->vctx->VideoProcessorSetStreamFrameFormat(s->processor,0,D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    s->vctx->VideoProcessorSetStreamSourceRect(s->processor,0,TRUE,&src);
    s->vctx->VideoProcessorSetStreamDestRect(s->processor,0,TRUE,&dst);
    hr=s->vctx->VideoProcessorBlt(s->processor,ov,0,1,&st);
    if(SUCCEEDED(hr))hr=s->swap->Present(1,0);
    rel(ov);rel(iv);rel(back);
    if(SUCCEEDED(hr)&&s->cb.on_presented)s->cb.on_presented(s->cb.opaque,pts);
    return SUCCEEDED(hr)?0:-8;
}

void lixh_surface_flush(void*surface){
    auto*s=(LixhWinSurface*)surface;
    if(s&&s->swap){s->ctx->ClearState();}
}

void lixh_surface_destroy(void*surface){
    auto*s=(LixhWinSurface*)surface;if(!s)return;
    clear_processor(s);rel(s->swap);rel(s->vctx);rel(s->video);rel(s->ctx);rel(s->dev);
    if(s->hwnd)DestroyWindow(s->hwnd);
    if(s->cb.on_closed)s->cb.on_closed(s->cb.opaque);
    delete s;
}
#endif

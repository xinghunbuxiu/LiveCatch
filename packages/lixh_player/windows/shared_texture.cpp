#include "shared_texture.h"

#include <cstring>

namespace lixh_player {

SharedTextureBridge::SharedTextureBridge() = default;

SharedTextureBridge::~SharedTextureBridge() { ReleasePair(); }

bool SharedTextureBridge::EnsureDevice() {
  if (device_) {
    return true;
  }
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  UINT flags =
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, &level, 1, D3D11_SDK_VERSION, &device_,
                                 nullptr, &context_);
  if (FAILED(hr)) {
    flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                           &level, 1, D3D11_SDK_VERSION, &device_, nullptr,
                           &context_);
  }
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                           &level, 1, D3D11_SDK_VERSION, &device_, nullptr,
                           &context_);
  }
  return SUCCEEDED(hr);
}

bool SharedTextureBridge::Initialize(uint32_t width, uint32_t height) {
  std::lock_guard<std::mutex> lock(mu_);
  if (width == 0 || height == 0) {
    return false;
  }
  if (!EnsureDevice()) {
    return false;
  }
  return CreatePair(width, height);
}

bool SharedTextureBridge::InitializeWithDevice(ID3D11Device* device,
                                               uint32_t width,
                                               uint32_t height) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!device || width == 0 || height == 0) {
    return false;
  }
  // Recreate on device change or stream size change. Old shared HANDLEs are
  // retired (not closed immediately) so Flutter can finish the prior frame.
  if (device_.Get() != device) {
    RetireCurrentPair();
    ReleaseVideoProcessor();
    device_ = device;
    context_.Reset();
    device_->GetImmediateContext(&context_);
    return CreatePair(width, height);
  }
  if (!ready_ || width_ != width || height_ != height) {
    ReleaseVideoProcessor();
    return CreatePair(width, height);
  }
  return true;
}

void SharedTextureBridge::Resize(uint32_t width, uint32_t height) {
  std::lock_guard<std::mutex> lock(mu_);
  if (width == width_ && height == height_ && ready_) {
    return;
  }
  if (!device_ && !EnsureDevice()) {
    return;
  }
  CreatePair(width, height);
}

void SharedTextureBridge::TickRetired() {
  for (auto it = retired_.begin(); it != retired_.end();) {
    if (--it->frames_left <= 0) {
      for (int i = 0; i < 2; ++i) {
        it->rtvs[i].Reset();
        it->textures[i].Reset();
        if (it->handles[i]) {
          CloseHandle(it->handles[i]);
          it->handles[i] = nullptr;
        }
      }
      it = retired_.erase(it);
    } else {
      ++it;
    }
  }
}

void SharedTextureBridge::RetireCurrentPair() {
  if (!textures_[0] && !handles_[0] && !handles_[1]) {
    ready_ = false;
    width_ = height_ = 0;
    return;
  }
  RetiredPair retired;
  for (int i = 0; i < 2; ++i) {
    retired.textures[i] = textures_[i];
    retired.rtvs[i] = rtvs_[i];
    retired.handles[i] = handles_[i];
    textures_[i].Reset();
    rtvs_[i].Reset();
    handles_[i] = nullptr;
  }
  retired_.push_back(std::move(retired));
  ready_ = false;
  // Keep width_/height_ until CreatePair assigns new ones so device-switch
  // can reuse Flutter texture dimensions.
}

bool SharedTextureBridge::CreatePair(uint32_t width, uint32_t height) {
  RetireCurrentPair();
  if (!device_ || width == 0 || height == 0) {
    return false;
  }

  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags =
      D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;

  for (int i = 0; i < 2; ++i) {
    HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &textures_[i]);
    if (FAILED(hr)) {
      ReleasePair();
      return false;
    }
    hr = device_->CreateRenderTargetView(textures_[i].Get(), nullptr,
                                         &rtvs_[i]);
    if (FAILED(hr)) {
      ReleasePair();
      return false;
    }
    Microsoft::WRL::ComPtr<IDXGIResource1> resource;
    hr = textures_[i].As(&resource);
    if (FAILED(hr)) {
      ReleasePair();
      return false;
    }
    hr = resource->CreateSharedHandle(
        nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
        nullptr, &handles_[i]);
    if (FAILED(hr) || handles_[i] == nullptr) {
      ReleasePair();
      return false;
    }
  }

  width_ = width;
  height_ = height;
  write_index_ = 0;
  read_index_ = 1;
  ready_ = true;

  const float black[4] = {0.f, 0.f, 0.f, 1.f};
  for (int i = 0; i < 2; ++i) {
    context_->ClearRenderTargetView(rtvs_[i].Get(), black);
  }
  context_->Flush();
  return true;
}

void SharedTextureBridge::ReleaseVpViews() {
  vp_out_views_[0].Reset();
  vp_out_views_[1].Reset();
  for (auto& v : vp_in_views_) {
    v.Reset();
  }
  vp_in_tex_ = nullptr;
  vp_stream_configured_ = false;
}

void SharedTextureBridge::ReleaseVideoProcessor() {
  ReleaseVpViews();
  vp_.Reset();
  vp_enum_.Reset();
  video_context_.Reset();
  video_device_.Reset();
  vp_in_w_ = vp_in_h_ = vp_out_w_ = vp_out_h_ = 0;
}

void SharedTextureBridge::ReleasePair() {
  ReleaseVideoProcessor();
  RetireCurrentPair();
  for (auto& r : retired_) {
    r.frames_left = 0;
  }
  TickRetired();
  staging_.Reset();
  staging_w_ = staging_h_ = 0;
  width_ = 0;
  height_ = 0;
  ready_ = false;
  std::memset(&descriptor_, 0, sizeof(descriptor_));
}

bool SharedTextureBridge::EnsureVideoProcessor(uint32_t in_w, uint32_t in_h,
                                               uint32_t out_w,
                                               uint32_t out_h) {
  if (vp_ && vp_in_w_ == in_w && vp_in_h_ == in_h && vp_out_w_ == out_w &&
      vp_out_h_ == out_h && video_device_ && video_context_) {
    return true;
  }
  ReleaseVideoProcessor();
  if (!device_ || !context_) {
    return false;
  }
  if (FAILED(device_.As(&video_device_)) || !video_device_) {
    return false;
  }
  if (FAILED(context_.As(&video_context_)) || !video_context_) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC content = {};
  content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  content.InputFrameRate = {60, 1};
  content.InputWidth = in_w;
  content.InputHeight = in_h;
  content.OutputFrameRate = {60, 1};
  content.OutputWidth = out_w;
  content.OutputHeight = out_h;
  content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;

  if (FAILED(video_device_->CreateVideoProcessorEnumerator(&content,
                                                           &vp_enum_)) ||
      !vp_enum_) {
    ReleaseVideoProcessor();
    return false;
  }

  UINT caps = 0;
  if (FAILED(vp_enum_->CheckVideoProcessorFormat(DXGI_FORMAT_NV12, &caps)) ||
      (caps & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT) == 0) {
    ReleaseVideoProcessor();
    return false;
  }
  caps = 0;
  if (FAILED(vp_enum_->CheckVideoProcessorFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                                 &caps)) ||
      (caps & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT) == 0) {
    ReleaseVideoProcessor();
    return false;
  }

  if (FAILED(video_device_->CreateVideoProcessor(vp_enum_.Get(), 0, &vp_)) ||
      !vp_) {
    ReleaseVideoProcessor();
    return false;
  }

  vp_in_w_ = in_w;
  vp_in_h_ = in_h;
  vp_out_w_ = out_w;
  vp_out_h_ = out_h;
  ReleaseVpViews();
  return true;
}

bool SharedTextureBridge::EnsureVpOutputView(int index) {
  if (index < 0 || index > 1 || !textures_[index] || !video_device_ ||
      !vp_enum_) {
    return false;
  }
  if (vp_out_views_[index]) {
    return true;
  }
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {};
  ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  ovd.Texture2D.MipSlice = 0;
  return SUCCEEDED(video_device_->CreateVideoProcessorOutputView(
             textures_[index].Get(), vp_enum_.Get(), &ovd,
             &vp_out_views_[index])) &&
         vp_out_views_[index];
}

bool SharedTextureBridge::EnsureVpInputView(ID3D11Texture2D* source,
                                            UINT subresource) {
  if (!source || !video_device_ || !vp_enum_) {
    return false;
  }
  if (source != vp_in_tex_) {
    for (auto& v : vp_in_views_) {
      v.Reset();
    }
    vp_in_tex_ = source;
  }
  if (subresource >= kMaxVpInputSlices) {
    // Rare oversized array — one-shot view (no cache slot).
    return false;
  }
  if (vp_in_views_[subresource]) {
    return true;
  }
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
  ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  ivd.Texture2D.MipSlice = 0;
  ivd.Texture2D.ArraySlice = subresource;
  return SUCCEEDED(video_device_->CreateVideoProcessorInputView(
             source, vp_enum_.Get(), &ivd, &vp_in_views_[subresource])) &&
         vp_in_views_[subresource];
}

bool SharedTextureBridge::PresentNv12ViaVideoProcessor(
    ID3D11Texture2D* source, UINT subresource) {
  D3D11_TEXTURE2D_DESC src_desc = {};
  source->GetDesc(&src_desc);
  const uint32_t in_w = src_desc.Width;
  const uint32_t in_h = src_desc.Height;
  if (!ready_ && !CreatePair(in_w, in_h)) {
    return false;
  }
  const uint32_t out_w = width_;
  const uint32_t out_h = height_;
  if (!EnsureVideoProcessor(in_w, in_h, out_w, out_h)) {
    return false;
  }
  if (!EnsureVpOutputView(write_index_)) {
    return false;
  }

  ID3D11VideoProcessorInputView* input_view = nullptr;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorInputView> oneshot;
  if (EnsureVpInputView(source, subresource)) {
    input_view = vp_in_views_[subresource].Get();
  } else {
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ivd.Texture2D.MipSlice = 0;
    ivd.Texture2D.ArraySlice = subresource;
    if (FAILED(video_device_->CreateVideoProcessorInputView(
            source, vp_enum_.Get(), &ivd, &oneshot)) ||
        !oneshot) {
      return false;
    }
    input_view = oneshot.Get();
  }

  if (!vp_stream_configured_) {
    RECT src_rect = {0, 0, static_cast<LONG>(in_w), static_cast<LONG>(in_h)};
    RECT dst_rect = {0, 0, static_cast<LONG>(out_w), static_cast<LONG>(out_h)};
    video_context_->VideoProcessorSetStreamFrameFormat(
        vp_.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    video_context_->VideoProcessorSetStreamSourceRect(vp_.Get(), 0, TRUE,
                                                      &src_rect);
    video_context_->VideoProcessorSetStreamDestRect(vp_.Get(), 0, TRUE,
                                                    &dst_rect);
    video_context_->VideoProcessorSetOutputTargetRect(vp_.Get(), TRUE,
                                                      &dst_rect);
    vp_stream_configured_ = true;
  }

  D3D11_VIDEO_PROCESSOR_STREAM stream = {};
  stream.Enable = TRUE;
  stream.pInputSurface = input_view;

  const HRESULT hr = video_context_->VideoProcessorBlt(
      vp_.Get(), vp_out_views_[write_index_].Get(), 0, 1, &stream);
  if (FAILED(hr)) {
    return false;
  }
  read_index_ = write_index_;
  write_index_ = 1 - write_index_;
  // Submit GPU work every 3rd frame — enough for shared HANDLE visibility.
  if ((++flush_div_ % 3) == 0) {
    context_->Flush();
  }
  TickRetired();
  return true;
}

bool SharedTextureBridge::PresentColor(float r, float g, float b) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!ready_) {
    return false;
  }
  const float color[4] = {r, g, b, 1.f};
  context_->ClearRenderTargetView(rtvs_[write_index_].Get(), color);
  context_->Flush();
  read_index_ = write_index_;
  write_index_ = 1 - write_index_;
  TickRetired();
  return true;
}

bool SharedTextureBridge::PresentFromTexture(ID3D11Texture2D* source,
                                             UINT subresource) {
  std::lock_guard<std::mutex> lock(mu_);
  if (source == nullptr || !device_) {
    return false;
  }
  Microsoft::WRL::ComPtr<ID3D11Device> src_device;
  source->GetDevice(&src_device);
  if (src_device.Get() != device_.Get()) {
    return false;
  }
  D3D11_TEXTURE2D_DESC src_desc = {};
  source->GetDesc(&src_desc);

  if (src_desc.Format == DXGI_FORMAT_NV12) {
    return PresentNv12ViaVideoProcessor(source, subresource);
  }
  if (!ready_) {
    return false;
  }
  if (src_desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM &&
      src_desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
    return false;
  }
  // Same-size copy only; avoid recreating shared handles mid-flight.
  if (src_desc.Width != width_ || src_desc.Height != height_) {
    return false;
  }
  context_->CopySubresourceRegion(textures_[write_index_].Get(), 0, 0, 0, 0,
                                  source, subresource, nullptr);
  read_index_ = write_index_;
  write_index_ = 1 - write_index_;
  if ((++flush_div_ % 3) == 0) {
    context_->Flush();
  }
  TickRetired();
  return true;
}

bool SharedTextureBridge::CaptureFromTexture(ID3D11Texture2D* source,
                                             UINT subresource) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!source || !device_ || !context_) {
    return false;
  }
  Microsoft::WRL::ComPtr<ID3D11Device> src_device;
  source->GetDevice(&src_device);
  if (src_device.Get() != device_.Get()) {
    return false;
  }
  D3D11_TEXTURE2D_DESC src_desc = {};
  source->GetDesc(&src_desc);
  if (src_desc.Format != DXGI_FORMAT_NV12 &&
      src_desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM &&
      src_desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
    return false;
  }
  const int idx = capture_write_;
  if (!capture_tex_[idx] || capture_fmt_[idx] != src_desc.Format ||
      capture_w_[idx] != src_desc.Width || capture_h_[idx] != src_desc.Height) {
    capture_tex_[idx].Reset();
    D3D11_TEXTURE2D_DESC desc = src_desc;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.MiscFlags = 0;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = 0;
    desc.Usage = D3D11_USAGE_DEFAULT;
    if (FAILED(device_->CreateTexture2D(&desc, nullptr, &capture_tex_[idx]))) {
      return false;
    }
    capture_fmt_[idx] = src_desc.Format;
    capture_w_[idx] = src_desc.Width;
    capture_h_[idx] = src_desc.Height;
  }
  context_->CopySubresourceRegion(capture_tex_[idx].Get(), 0, 0, 0, 0, source,
                                  subresource, nullptr);
  capture_ready_ = idx;
  capture_write_ = 1 - idx;
  capture_bgra_ready_ = false;
  return true;
}

bool SharedTextureBridge::CaptureBgra(const uint8_t* bgra, uint32_t width,
                                      uint32_t height, uint32_t stride) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!bgra || width == 0 || height == 0) {
    return false;
  }
  const size_t row = static_cast<size_t>(width) * 4;
  const size_t need = row * height;
  if (capture_bgra_.size() != need) {
    capture_bgra_.assign(need, 0);
  }
  for (uint32_t y = 0; y < height; ++y) {
    std::memcpy(capture_bgra_.data() + y * row, bgra + y * stride, row);
  }
  capture_bgra_w_ = width;
  capture_bgra_h_ = height;
  capture_bgra_ready_ = true;
  capture_ready_ = -1;
  return true;
}

bool SharedTextureBridge::PublishCaptured() {
  Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
  DXGI_FORMAT fmt = DXGI_FORMAT_UNKNOWN;
  uint32_t w = 0, h = 0;
  std::vector<uint8_t> bgra;
  uint32_t bw = 0, bh = 0;
  bool have_bgra = false;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (capture_bgra_ready_) {
      bgra.swap(capture_bgra_);
      bw = capture_bgra_w_;
      bh = capture_bgra_h_;
      capture_bgra_ready_ = false;
      have_bgra = true;
    } else if (capture_ready_ >= 0) {
      const int idx = capture_ready_;
      capture_ready_ = -1;
      tex = capture_tex_[idx];
      fmt = capture_fmt_[idx];
      w = capture_w_[idx];
      h = capture_h_[idx];
    } else {
      return false;
    }
  }
  if (have_bgra) {
    return PresentBgra(bgra.data(), bw, bh, bw * 4);
  }
  if (!tex) {
    return false;
  }
  if (fmt == DXGI_FORMAT_NV12 || fmt == DXGI_FORMAT_B8G8R8A8_UNORM ||
      fmt == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
    if (!ready_ || width_ != w || height_ != h) {
      if (!InitializeWithDevice(device_.Get(), w, h)) {
        return false;
      }
    }
    return PresentFromTexture(tex.Get(), 0);
  }
  return false;
}

bool SharedTextureBridge::PresentBgra(const uint8_t* bgra, uint32_t width,
                                      uint32_t height, uint32_t stride) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!bgra || width == 0 || height == 0) {
    return false;
  }
  if (!device_ && !EnsureDevice()) {
    return false;
  }
  if (!ready_ || width != width_ || height != height_) {
    if (!CreatePair(width, height)) {
      return false;
    }
  }
  if (!staging_ || staging_w_ != width || staging_h_ != height) {
    staging_.Reset();
    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DYNAMIC;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(device_->CreateTexture2D(&desc, nullptr, &staging_))) {
      return false;
    }
    staging_w_ = width;
    staging_h_ = height;
  }
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(context_->Map(staging_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0,
                           &mapped))) {
    return false;
  }
  auto* dst = static_cast<uint8_t*>(mapped.pData);
  for (uint32_t y = 0; y < height; ++y) {
    std::memcpy(dst + y * mapped.RowPitch, bgra + y * stride, width * 4);
  }
  context_->Unmap(staging_.Get(), 0);
  context_->CopyResource(textures_[write_index_].Get(), staging_.Get());
  read_index_ = write_index_;
  write_index_ = 1 - write_index_;
  if ((++flush_div_ % 3) == 0) {
    context_->Flush();
  }
  TickRetired();
  return true;
}

const FlutterDesktopGpuSurfaceDescriptor* SharedTextureBridge::Descriptor() {
  std::lock_guard<std::mutex> lock(mu_);
  if (!ready_) {
    return nullptr;
  }
  descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  descriptor_.handle = handles_[read_index_];
  descriptor_.width = width_;
  descriptor_.height = height_;
  descriptor_.visible_width = width_;
  descriptor_.visible_height = height_;
  descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
  descriptor_.release_callback = nullptr;
  descriptor_.release_context = nullptr;
  return &descriptor_;
}

}  // namespace lixh_player

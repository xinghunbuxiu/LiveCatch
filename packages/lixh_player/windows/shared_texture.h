#ifndef LIXH_PLAYER_SHARED_TEXTURE_H_
#define LIXH_PLAYER_SHARED_TEXTURE_H_

#include <cstdint>
#include <mutex>
#include <vector>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <flutter_texture_registrar.h>

namespace lixh_player {

// Double-buffered DXGI-shareable D3D11 textures for Flutter
// kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle (GPU path, no CPU upload).
class SharedTextureBridge {
 public:
  SharedTextureBridge();
  ~SharedTextureBridge();

  // Create (or recreate) textures on a private HW/WARP device.
  bool Initialize(uint32_t width, uint32_t height);
  // Prefer this for D3D11VA: textures live on the decoder device so
  // VideoProcessor / CopySubresource stays on-GPU, then Flutter imports HANDLE.
  bool InitializeWithDevice(ID3D11Device* device, uint32_t width,
                            uint32_t height);
  void Resize(uint32_t width, uint32_t height);

  bool PresentColor(float r, float g, float b);
  // BGRA: CopySubresource. NV12 (D3D11VA): VideoProcessorBlt -> BGRA.
  bool PresentFromTexture(ID3D11Texture2D* source, UINT subresource);
  // Software / transferred frames: BGRA8888 tightly packed upload.
  bool PresentBgra(const uint8_t* bgra, uint32_t width, uint32_t height,
                   uint32_t stride);

  // Demux-thread: fast GPU copy into an owned double-buffer (no VP/Flush).
  // Present-thread: PublishCaptured() does VP/upload + Flush.
  bool CaptureFromTexture(ID3D11Texture2D* source, UINT subresource);
  bool CaptureBgra(const uint8_t* bgra, uint32_t width, uint32_t height,
                   uint32_t stride);
  // Returns true if a Flutter-visible frame was published.
  bool PublishCaptured();

  const FlutterDesktopGpuSurfaceDescriptor* Descriptor();
  ID3D11Device* device() const { return device_.Get(); }
  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }
  bool ready() const { return ready_; }

 private:
  struct RetiredPair {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> textures[2];
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtvs[2];
    HANDLE handles[2] = {nullptr, nullptr};
    int frames_left = 8;  // keep alive until Flutter drops old handles
  };

  bool EnsureDevice();
  bool CreatePair(uint32_t width, uint32_t height);
  void ReleasePair();
  void RetireCurrentPair();
  void TickRetired();
  void ReleaseVideoProcessor();
  void ReleaseVpViews();
  bool EnsureVideoProcessor(uint32_t in_w, uint32_t in_h, uint32_t out_w,
                            uint32_t out_h);
  bool EnsureVpOutputView(int index);
  bool EnsureVpInputView(ID3D11Texture2D* source, UINT subresource);
  bool PresentNv12ViaVideoProcessor(ID3D11Texture2D* source, UINT subresource);

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> textures_[2];
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtvs_[2];
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;

  // Latest-wins capture slot for async present (demux never waits on Flush).
  Microsoft::WRL::ComPtr<ID3D11Texture2D> capture_tex_[2];
  DXGI_FORMAT capture_fmt_[2] = {DXGI_FORMAT_UNKNOWN, DXGI_FORMAT_UNKNOWN};
  uint32_t capture_w_[2] = {0, 0};
  uint32_t capture_h_[2] = {0, 0};
  int capture_write_ = 0;
  int capture_ready_ = -1;  // index ready for PublishCaptured, or -1
  std::vector<uint8_t> capture_bgra_;
  uint32_t capture_bgra_w_ = 0;
  uint32_t capture_bgra_h_ = 0;
  bool capture_bgra_ready_ = false;

  Microsoft::WRL::ComPtr<ID3D11VideoDevice> video_device_;
  Microsoft::WRL::ComPtr<ID3D11VideoContext> video_context_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> vp_enum_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessor> vp_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorOutputView> vp_out_views_[2];
  // D3D11VA decode surfaces are array slices on one texture — cache by slice.
  static constexpr UINT kMaxVpInputSlices = 32;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorInputView>
      vp_in_views_[kMaxVpInputSlices];
  ID3D11Texture2D* vp_in_tex_ = nullptr;
  bool vp_stream_configured_ = false;
  uint32_t vp_in_w_ = 0;
  uint32_t vp_in_h_ = 0;
  uint32_t vp_out_w_ = 0;
  uint32_t vp_out_h_ = 0;
  int flush_div_ = 0;

  HANDLE handles_[2] = {nullptr, nullptr};
  std::vector<RetiredPair> retired_;
  FlutterDesktopGpuSurfaceDescriptor descriptor_{};
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  uint32_t staging_w_ = 0;
  uint32_t staging_h_ = 0;
  int write_index_ = 0;
  int read_index_ = 0;
  bool ready_ = false;
  std::mutex mu_;
};

}  // namespace lixh_player

#endif  // LIXH_PLAYER_SHARED_TEXTURE_H_

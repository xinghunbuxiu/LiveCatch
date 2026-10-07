use std::fs;
use std::path::Path;

fn ensure_windows_icon() {
    let path = Path::new("icons/icon.ico");
    if path.exists() {
        return;
    }

    fs::create_dir_all("icons").expect("create Tauri icon directory");

    // Minimal valid 1x1 32-bit ICO. This keeps cargo check/build portable
    // when the repository does not ship a generated application icon.
    let mut ico = Vec::with_capacity(70);
    ico.extend_from_slice(&[0, 0, 1, 0, 1, 0]);
    ico.extend_from_slice(&[1, 1, 0, 0, 1, 0, 32, 0]);
    ico.extend_from_slice(&(40u32 + 4 + 4).to_le_bytes());
    ico.extend_from_slice(&22u32.to_le_bytes());
    ico.extend_from_slice(&40u32.to_le_bytes());
    ico.extend_from_slice(&1i32.to_le_bytes());
    ico.extend_from_slice(&2i32.to_le_bytes());
    ico.extend_from_slice(&1u16.to_le_bytes());
    ico.extend_from_slice(&32u16.to_le_bytes());
    ico.extend_from_slice(&0u32.to_le_bytes());
    ico.extend_from_slice(&4u32.to_le_bytes());
    ico.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
    ico.extend_from_slice(&[0, 0, 0, 0]);
    ico.extend_from_slice(&[0, 0, 0, 0]);
    fs::write(path, ico).expect("write fallback Tauri icon");
}

fn ensure_png_icon() {
    let path = Path::new("icons/icon.png");
    if path.exists() {
        return;
    }

    fs::create_dir_all("icons").expect("create Tauri icon directory");

    // Minimal valid 1x1 RGBA PNG (transparent pixel).
    // Tauri's generate_context! reads icon.png at compile time even when
    // no explicit bundle.icon entry is configured.
    const PNG: &[u8] = &[
        0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,
        0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,
        0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
        0x08,0x06,0x00,0x00,0x00,0x1f,0x15,0xc4,0x89,
        0x00,0x00,0x00,0x0d,0x49,0x44,0x41,0x54,
        0x78,0x9c,0x63,0x60,0x00,0x00,0x00,0x02,0x00,0x01,
        0xe5,0x27,0xd4,0xa2,
        0x00,0x00,0x00,0x00,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82,
    ];
    fs::write(path, PNG).expect("write fallback Tauri PNG icon");
}

fn main() {
    ensure_windows_icon();
    ensure_png_icon();
    tauri_build::build();
}

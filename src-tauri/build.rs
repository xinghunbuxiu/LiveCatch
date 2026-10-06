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
    ico.extend_from_slice(&70u32.to_le_bytes());
    ico.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
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

fn main() {
    ensure_windows_icon();
    tauri_build::build();
}

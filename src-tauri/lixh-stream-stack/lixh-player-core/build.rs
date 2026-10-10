use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=native/lixh_player.c");
    println!("cargo:rerun-if-changed=include/lixh_player.h");
    println!("cargo:rerun-if-changed=include/lixh_surface.h");
    println!("cargo:rerun-if-changed=native/lixh_surface_macos.m");
    // Windows surface lives in src/surface_windows.rs (no C++ object).

    let mut b = cc::Build::new();
    b.file("native/lixh_player.c")
        .include("include")
        .warnings(true)
        .flag_if_supported("-std=c11")
        .flag_if_supported("/std:c11")
        .flag_if_supported("/experimental:c11atomics");

    if let Ok(root) = env::var("LIXH_FFMPEG_DIR") {
        let root = PathBuf::from(root);
        b.include(root.join("include"));
        let lib_dir = root.join("lib");
        println!("cargo:rustc-link-search=native={}", lib_dir.display());

        if cfg!(target_os = "macos") {
            let normalizer = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../scripts/normalize-ffmpeg-macos.sh");
            let status = Command::new("bash")
                .arg(&normalizer)
                .arg(&root)
                .status()
                .expect("failed to run FFmpeg macOS install-name normalizer");
            assert!(status.success(), "FFmpeg macOS install-name normalization failed");
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
        }

        // Windows: do NOT link swscale. The bundled MinGW-built swscale DLL
        // depends on libgcc_s_seh-1.dll (absent on end-user machines), which
        // breaks process startup (STATUS_DLL_NOT_FOUND). Software frames are
        // converted to NV12 by hand in src/surface_windows.rs instead.
        let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        if target_os == "windows" {
            for lib in ["avformat", "avcodec", "avutil", "swresample"] {
                println!("cargo:rustc-link-lib=dylib={lib}");
            }
        } else {
            for lib in ["avformat", "avcodec", "avutil", "swresample", "swscale"] {
                println!("cargo:rustc-link-lib=dylib={lib}");
            }
        }
    }

    if cfg!(target_os = "windows") {
        b.define("LIXH_WINDOWS", None);
    }
    if cfg!(target_os = "macos") {
        b.define("LIXH_MACOS", None);
    }
    b.compile("lixh_player");

    if cfg!(target_os = "macos") {
        let mut surf = cc::Build::new();
        surf.file("native/lixh_surface_macos.m")
            .include("include")
            .flag_if_supported("-fobjc-arc");
        // Software-frame upload needs AVFrame layout (libavutil/frame.h).
        if let Ok(root) = env::var("LIXH_FFMPEG_DIR") {
            surf.include(PathBuf::from(root).join("include"));
        }
        surf.compile("lixh_surface_macos");
        for fw in ["Cocoa", "AVFoundation", "CoreMedia", "CoreVideo"] {
            println!("cargo:rustc-link-lib=framework={fw}");
        }
    }
    // Windows: the video surface bridge is implemented directly in Rust
    // (src/surface_windows.rs); the `windows` crate links system libraries
    // itself via #[link] attributes. No C++ surface object on this platform.
    if cfg!(target_os = "windows") {
        println!("cargo:rerun-if-changed=src/surface_windows.rs");
    }
}

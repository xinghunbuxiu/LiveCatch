use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=native/lixh_player.c");
    println!("cargo:rerun-if-changed=include/lixh_player.h");
    println!("cargo:rerun-if-changed=include/lixh_surface.h");
    println!("cargo:rerun-if-changed=native/lixh_surface_macos.m");
    println!("cargo:rerun-if-changed=native/lixh_surface_windows.cpp");

    let mut b = cc::Build::new();
    b.file("native/lixh_player.c")
        .include("include")
        .warnings(true)
        .flag_if_supported("-std=c11")
        .flag_if_supported("/std:c11");

    if let Ok(root) = env::var("LIXH_FFMPEG_DIR") {
        let root = PathBuf::from(root);
        b.include(root.join("include"));
        println!("cargo:rustc-link-search=native={}", root.join("lib").display());
        for lib in ["avformat", "avcodec", "avutil", "swresample", "swscale"] {
            println!("cargo:rustc-link-lib=dylib={lib}");
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
        cc::Build::new()
            .file("native/lixh_surface_macos.m")
            .include("include")
            .flag_if_supported("-fobjc-arc")
            .compile("lixh_surface_macos");
        for fw in ["Cocoa", "AVFoundation", "CoreMedia", "CoreVideo"] {
            println!("cargo:rustc-link-lib=framework={fw}");
        }
    }
    if cfg!(target_os = "windows") {
        cc::Build::new()
            .cpp(true)
            .file("native/lixh_surface_windows.cpp")
            .include("include")
            .flag_if_supported("/std:c++17")
            .compile("lixh_surface_windows");
        println!("cargo:rustc-link-lib=d3d11");
        println!("cargo:rustc-link-lib=dxgi");
    }
}

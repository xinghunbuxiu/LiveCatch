use std::env;
use std::path::Path;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=LIXH_FFMPEG_DIR");

    if env::var("CARGO_CFG_TARGET_OS").ok().as_deref() != Some("macos") {
        return;
    }

    let Some(root) = env::var_os("LIXH_FFMPEG_DIR") else {
        return;
    };
    let lib = Path::new(&root).join("lib");
    if !lib.is_dir() {
        return;
    }

    let normalizer = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../scripts/normalize-ffmpeg-macos.sh");
    let output = Command::new("bash")
        .arg(&normalizer)
        .arg(&root)
        .output()
        .expect("failed to run FFmpeg macOS install-name normalizer");
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        panic!(
            "FFmpeg macOS install-name normalization failed (status {:?})\nstdout:\n{stdout}\nstderr:\n{stderr}",
            output.status.code()
        );
    }

    let rpath = lib.to_string_lossy();
    println!("cargo:rustc-link-arg=-Wl,-rpath,{rpath}");
}

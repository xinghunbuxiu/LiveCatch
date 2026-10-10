call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set PATH=C:\Users\admin\nodeport\node-v22.19.0-win-x64;C:\Users\admin\.cargo\bin;C:\Users\admin\protoc\bin;%PATH%
set PROTOC=C:\Users\admin\protoc\bin\protoc.exe
set LIXH_FFMPEG_DIR=C:\Users\admin\liveCatch\src-tauri\lixh-stream-stack\sdk\windows-x64
set PATH=C:\Users\admin\liveCatch\src-tauri\lixh-stream-stack\runtime\windows-x64;%PATH%
set CARGO_BUILD_JOBS=2
cd /d C:\Users\admin\liveCatch\src-tauri
cargo build --release --no-default-features -j2

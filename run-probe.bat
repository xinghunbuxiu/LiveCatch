call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cd /d C:\Users\admin\liveCatch
cl /nologo pixfmt-probe.c /I src-tauri\lixh-stream-stack\sdk\windows-x64\include /FeC:\Users\admin\pixfmt-probe.exe
C:\Users\admin\pixfmt-probe.exe

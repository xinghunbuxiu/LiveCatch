call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cd /d C:\Users\admin\liveCatch\src-tauri\lixh-stream-stack\lixh-player-core
cl /nologo /c /std:c++17 /I include /I C:\Users\admin\liveCatch\src-tauri\lixh-stream-stack\sdk\windows-x64\include native\lixh_surface_windows.cpp /FoC:\Users\admin\surf-test.obj

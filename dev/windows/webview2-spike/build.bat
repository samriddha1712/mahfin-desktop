@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
set ROOT=%~dp0..\..\..
set WV2=%ROOT%\build\packages\Microsoft.Web.WebView2.1.0.4258.31\build\native
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE spike.cpp /I"%WV2%\include" /I"%ROOT%\build\mpv\include" /link /SUBSYSTEM:CONSOLE /ENTRY:wWinMainCRTStartup "%WV2%\x64\WebView2LoaderStatic.lib" "%ROOT%\build\mpv\libmpv-2.dll.lib" user32.lib gdi32.lib ole32.lib oleaut32.lib advapi32.lib shell32.lib version.lib
if errorlevel 1 exit /b 1
copy /y "%ROOT%\build\mpv\libmpv-2.dll" . >nul

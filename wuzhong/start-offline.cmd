@echo off
setlocal

set "URHOX_RUNTIME=D:\SUMI\UrhoXEditor\UrhoXRuntime.exe"
set "PROJECT_DIR=%~dp0"
set "PROJECT_DIR_FWD=%PROJECT_DIR:\=/%"
set "PACKAGES=C:/Workspace/SCE/UrhoXRes/;E:/Workspace/Chameleon_3C_UrhoX/;C:/Maker/UrhoX/;%PROJECT_DIR_FWD%"

start "UrhoX Offline" "%URHOX_RUNTIME%" main.lua ^
  -editor_debug_tapcode ^
  -editor_debug="%PROJECT_DIR_FWD%" ^
  -editor_debug_packages="%PACKAGES%" ^
  -rendering_pipeline=deferred ^
  -skip_login

endlocal

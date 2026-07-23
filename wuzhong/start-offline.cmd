@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "PROJECT_DIR_FWD=%PROJECT_DIR:\=/%"

if exist "%PROJECT_DIR%start-offline.local.cmd" call "%PROJECT_DIR%start-offline.local.cmd"
if not defined URHOX_RUNTIME for /f "delims=" %%I in ('where UrhoXRuntime.exe 2^>nul') do if not defined URHOX_RUNTIME set "URHOX_RUNTIME=%%I"

if not defined URHOX_RUNTIME (
  echo [ERROR] URHOX_RUNTIME is not configured. Set it in start-offline.local.cmd or your environment.
  exit /b 1
)
if not exist "%URHOX_RUNTIME%" (
  echo [ERROR] UrhoX runtime not found: %URHOX_RUNTIME%
  exit /b 1
)

set "PACKAGES=%PROJECT_DIR_FWD%"
if defined URHOX_EXTRA_PACKAGES set "PACKAGES=%URHOX_EXTRA_PACKAGES%;%PACKAGES%"

start "UrhoX Offline" "%URHOX_RUNTIME%" main.lua ^
  -editor_debug_tapcode ^
  -editor_debug="%PROJECT_DIR_FWD%" ^
  -editor_debug_packages="%PACKAGES%" ^
  -rendering_pipeline=deferred ^
  -skip_login

endlocal

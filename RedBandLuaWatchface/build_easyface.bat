@echo off
setlocal
set "HERE=%~dp0"
set "COMPILER=%HERE%_toolchain\EasyFace_4.23\Compiler.exe"
if not exist "%COMPILER%" (
  echo [ERROR] EasyFace Compiler.exe not found at %COMPILER%
  echo You may open RedBandLua.fprj in the installed EasyFace 4.23 GUI.
  exit /b 1
)
"%COMPILER%" "%HERE%RedBandLua.fprj"
if errorlevel 1 exit /b 1
echo Finished. Locate the generated watchface in the EasyFace output directory.

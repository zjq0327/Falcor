@echo off
setlocal
pushd "%~dp0" || exit /b 1

set "RTPT_EXE=build\windows-vs2022\bin\Release\Mogwai.exe"
if not exist "%RTPT_EXE%" (
    echo Mogwai.exe was not found. Build the Release configuration first.
    if not "%RTPT_START_NO_PAUSE%"=="1" pause
    popd
    exit /b 1
)

rem Optional launch overrides also let validation exercise this exact entry point.
if not defined RTPT_START_SCRIPT set "RTPT_START_SCRIPT=scripts\RTPTSHARCNRD.py"
if not defined RTPT_START_SCENE set "RTPT_START_SCENE=test_scenes/cornell_box.pyscene"
"%RTPT_EXE%" --script "%RTPT_START_SCRIPT%" --scene "%RTPT_START_SCENE%" %*
set "RTPT_EXIT_CODE=%ERRORLEVEL%"
popd
if not "%RTPT_EXIT_CODE%"=="0" if not "%RTPT_START_NO_PAUSE%"=="1" pause
exit /b %RTPT_EXIT_CODE%

@echo off
setlocal
pushd "%~dp0" || exit /b 1

set "RTPT_EXE=build\windows-vs2022\bin\Release\Mogwai.exe"
if not exist "%RTPT_EXE%" (
    echo Mogwai.exe was not found. Build the Release configuration first.
    pause
    popd
    exit /b 1
)

"%RTPT_EXE%" --script "scripts\RTPTSHARCNRD.py" --scene "test_scenes/cornell_box.pyscene"
set "RTPT_EXIT_CODE=%ERRORLEVEL%"
popd
if not "%RTPT_EXIT_CODE%"=="0" pause
exit /b %RTPT_EXIT_CODE%

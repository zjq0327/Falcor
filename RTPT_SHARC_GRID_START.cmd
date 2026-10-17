@echo off
setlocal
pushd "%~dp0" || exit /b 1

set "RTPT_EXE=build\windows-vs2022\bin\Release\Mogwai.exe"
set "RTPT_SCRIPT=scripts\RTPTSHARCGrid.py"
set "RTPT_SCENE=Source\Data\VeachAjar\VeachAjarRTPT.pyscene"

if not exist "%RTPT_EXE%" (
    echo Mogwai.exe was not found. Build the Release configuration first.
    pause
    popd
    exit /b 1
)
if not exist "%RTPT_SCRIPT%" (
    echo SHaRC grid render script was not found: %RTPT_SCRIPT%
    pause
    popd
    exit /b 1
)
if not exist "%RTPT_SCENE%" (
    echo VeachAjar scene was not found: %RTPT_SCENE%
    pause
    popd
    exit /b 1
)

"%RTPT_EXE%" --script "%RTPT_SCRIPT%" --scene "%RTPT_SCENE%"
set "RTPT_EXIT_CODE=%ERRORLEVEL%"
popd
if not "%RTPT_EXIT_CODE%"=="0" pause
exit /b %RTPT_EXIT_CODE%

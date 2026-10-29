@echo off
setlocal
pushd "%~dp0" || exit /b 1

rem Module switches: 1 = enabled, 0 = disabled. These are local to this launch.
set "RTPT_SHARC_ENABLED=1"
set "RTPT_NRD_ENABLED=1"
rem Primary-hit reuse, compact split records and single surface writes are fixed on.
rem Experimental two-Pass VXPG NRD continuations; 0 keeps the original single Pass.
set "RTPT_NRD_SPLIT_ENABLED=1"
set "RTPT_ACCUMULATION_ENABLED=1"
set "RTPT_TONEMAPPER_ENABLED=1"
set "RTPT_LIGHT_GRID_ENABLED=1"
set "RTPT_LIGHT_GRID_CDF_ENABLED=1"
rem Grid resolution is the maximum axis cell count; budget reduces cells, never lights.
set "RTPT_LIGHT_GRID_RESOLUTION=16"
set "RTPT_LIGHT_GRID_PERSISTENT_ENABLED=1"
set "RTPT_LIGHT_TILE_ENABLED=1"
set "RTPT_LIGHT_TILE_ADAPTIVE_ENABLED=1"
set "RTPT_LOCAL_LIGHT_DEBUG_ENABLED=0"
set "RTPT_LOCAL_LIGHT_OVERLAY_ENABLED=0"
set "RTPT_GUIDING_MODE=VXPG"
set "RTPT_VXPG_ENABLED=1"
set "RTPT_VXPG_DEBUG_ENABLED=0"
set "RTPT_VXPG_DIAGNOSTICS_ENABLED=0"
rem VXPG always uses eligible PG SHaRC queries, Visibility, shared multi-bounce training, incremental sparse distance LOD, camera/history reuse, confidence and local tree updates.
set "RTPT_VXPG_DISCOVERY_STRIDE=5"
set "RTPT_VXPG_SPATIAL_STALE_FRAMES=512"
set "RTPT_VXPG_TREE_REFRESH_FRAMES=16"
set "RTPT_VXPG_HISTORY_FRAMES=32"
set "RTPT_VXPG_HISTORY_STALE_FRAMES=128"
set "RTPT_VXPG_LOD_SCENE_SCALE=8"
set "RTPT_VXPG_LOD_HASH_CAPACITY=65536"
set "RTPT_VXPG_LOD_GEOMETRY_CAPACITY=8192"
set "RTPT_VXPG_LOD_BUDGET_MB=256"

set "RTPT_EXE=build\windows-vs2022\bin\Release\Mogwai.exe"
rem Main entry point: keep the complete integrated rendering pipeline here.
set "RTPT_SCRIPT=scripts\RTPTSHARCNRD.py"
set "RTPT_SCENE=Source\Data\VeachAjar\VeachAjarRTPT.pyscene"

if not exist "%RTPT_EXE%" (
    echo Mogwai.exe was not found. Build the Release configuration first.
    pause
    popd
    exit /b 1
)
if not exist "%RTPT_SCRIPT%" (
    echo RTPT render script was not found: %RTPT_SCRIPT%
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

rem Forward optional Mogwai arguments, for example --headless for automated validation.
"%RTPT_EXE%" --device-type d3d12 --script "%RTPT_SCRIPT%" --scene "%RTPT_SCENE%" %*
set "RTPT_EXIT_CODE=%ERRORLEVEL%"
popd
if not "%RTPT_EXIT_CODE%"=="0" pause
exit /b %RTPT_EXIT_CODE%

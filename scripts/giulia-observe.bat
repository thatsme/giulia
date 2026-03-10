@echo off
REM Giulia Monitor — Observation Control (Build 135)
REM Usage:
REM   giulia-observe start nexus@192.168.10.174 [cookie] [interval_ms] [trace_modules]
REM   giulia-observe stop  nexus@192.168.10.174
REM   giulia-observe status
REM
REM Defaults:
REM   cookie        = nexus_shared_cookie
REM   interval_ms   = 5000
REM   trace_modules = (none)
REM   monitor       = http://localhost:4001
REM   worker        = http://giulia-worker:4000

setlocal enabledelayedexpansion

set MONITOR_URL=http://localhost:4001
set WORKER_URL=http://giulia-worker:4000
set DEFAULT_COOKIE=nexus_shared_cookie
set DEFAULT_INTERVAL=5000

if "%1"=="" goto :usage

if /i "%1"=="start" goto :start
if /i "%1"=="stop"  goto :stop
if /i "%1"=="status" goto :status
goto :usage

:start
if "%2"=="" (
    echo Error: node name required
    echo Example: giulia-observe start nexus@192.168.10.174
    exit /b 1
)
set NODE=%2
set COOKIE=%3
set INTERVAL=%4
set TRACE_MODULES=%5
if "%COOKIE%"=="" set COOKIE=%DEFAULT_COOKIE%
if "%INTERVAL%"=="" set INTERVAL=%DEFAULT_INTERVAL%

echo Connecting to %NODE% ...
curl -s -X POST %MONITOR_URL%/api/runtime/connect ^
  -H "Content-Type: application/json" ^
  -d "{\"node\":\"%NODE%\",\"cookie\":\"%COOKIE%\"}"
echo.
echo.

REM Build JSON payload — include trace_modules if provided
if "%TRACE_MODULES%"=="" (
    set BODY={\"node\":\"%NODE%\",\"cookie\":\"%COOKIE%\",\"worker_url\":\"%WORKER_URL%\",\"interval_ms\":%INTERVAL%}
    echo Starting observation ^(interval: %INTERVAL%ms^) ...
) else (
    REM Convert comma-separated modules to JSON array: "A,B" -> ["\"A\"","\"B\""]
    set "TRACE_JSON=!TRACE_MODULES:,=","!"
    set "TRACE_JSON=\"!TRACE_JSON!\""
    set BODY={\"node\":\"%NODE%\",\"cookie\":\"%COOKIE%\",\"worker_url\":\"%WORKER_URL%\",\"interval_ms\":%INTERVAL%,\"trace_modules\":[!TRACE_JSON!]}
    echo Starting observation ^(interval: %INTERVAL%ms, tracing: %TRACE_MODULES%^) ...
)

curl -s -X POST %MONITOR_URL%/api/monitor/observe/start ^
  -H "Content-Type: application/json" ^
  -d "!BODY!"
echo.
echo.
echo Observation running. Run your tests, then: giulia-observe stop %NODE%
goto :eof

:stop
if "%2"=="" (
    echo Error: node name required
    echo Example: giulia-observe stop nexus@192.168.10.174
    exit /b 1
)
set NODE=%2

echo Stopping observation of %NODE% ...
curl -s -X POST %MONITOR_URL%/api/monitor/observe/stop ^
  -H "Content-Type: application/json" ^
  -d "{\"node\":\"%NODE%\"}"
echo.
echo.
echo Observation stopped. Worker is finalizing data.
echo Query results: curl %MONITOR_URL:~0,-4%4000/api/runtime/observations
goto :eof

:status
echo Observation status:
curl -s %MONITOR_URL%/api/monitor/observe/status
echo.
goto :eof

:usage
echo.
echo Giulia Observation Control (Build 135)
echo.
echo Usage:
echo   giulia-observe start ^<node^> [cookie] [interval_ms] [trace_modules]
echo   giulia-observe stop  ^<node^>
echo   giulia-observe status
echo.
echo Examples:
echo   giulia-observe start nexus@192.168.10.174
echo   giulia-observe start nexus@192.168.10.174 my_cookie 3000
echo   giulia-observe start nexus@192.168.10.174 my_cookie 5000 Nexus.Repo,Nexus.Registry.TableRegistry
echo   giulia-observe stop nexus@192.168.10.174
echo   giulia-observe status
echo.
echo Defaults:
echo   cookie        = %DEFAULT_COOKIE%
echo   interval_ms   = %DEFAULT_INTERVAL%
echo   trace_modules = (none — process-level only)
echo   monitor       = %MONITOR_URL%
echo   worker        = %WORKER_URL%
echo.
exit /b 0

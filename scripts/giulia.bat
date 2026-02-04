@echo off
REM Giulia Thin Client Wrapper for Windows
REM This script handles Docker daemon management and path mapping

setlocal enabledelayedexpansion

set GIULIA_CONTAINER=giulia-daemon
set GIULIA_IMAGE=giulia/core:latest

REM Check if Docker is running
docker info >nul 2>&1
if errorlevel 1 (
    echo Error: Docker is not running. Please start Docker Desktop.
    exit /b 1
)

REM Check if daemon container is running
docker ps -q -f "name=%GIULIA_CONTAINER%" >nul 2>&1
for /f %%i in ('docker ps -q -f "name=%GIULIA_CONTAINER%"') do set CONTAINER_ID=%%i

if "%CONTAINER_ID%"=="" (
    echo Starting Giulia daemon...

    REM Get current drive letter and convert to Docker mount format
    set CURRENT_DIR=%CD%
    set DRIVE_LETTER=%CURRENT_DIR:~0,1%
    set REST_PATH=%CURRENT_DIR:~2%
    set REST_PATH=%REST_PATH:\=/%

    REM Default projects path is parent of current directory
    if "%GIULIA_PROJECTS_PATH%"=="" (
        for %%i in ("%CD%\..") do set PROJECTS_PATH=%%~fi
        set PROJECTS_PATH=!PROJECTS_PATH:\=/!
        set DRIVE=!PROJECTS_PATH:~0,1!
        set PREST=!PROJECTS_PATH:~2!
        set GIULIA_PROJECTS_PATH=//!DRIVE!!PREST!
    )

    docker run -d ^
        --name %GIULIA_CONTAINER% ^
        --hostname giulia-daemon ^
        -v giulia_data:/data ^
        -v "%GIULIA_PROJECTS_PATH%:/projects" ^
        -p 4369:4369 ^
        -p 9100-9105:9100-9105 ^
        -e RELEASE_NODE=giulia@giulia-daemon ^
        -e RELEASE_COOKIE=giulia_cluster_secret ^
        -e LM_STUDIO_URL=http://host.docker.internal:1234/v1/chat/completions ^
        %GIULIA_IMAGE%

    if errorlevel 1 (
        echo Failed to start daemon. Is the image built?
        echo Run: docker-compose build
        exit /b 1
    )

    REM Wait for daemon to be ready
    timeout /t 3 /nobreak >nul
    echo Daemon started.
)

REM Handle commands
if "%1"=="/stop" (
    echo Stopping Giulia daemon...
    docker stop %GIULIA_CONTAINER% >nul 2>&1
    docker rm %GIULIA_CONTAINER% >nul 2>&1
    echo Daemon stopped.
    exit /b 0
)

if "%1"=="/logs" (
    docker logs -f %GIULIA_CONTAINER%
    exit /b 0
)

if "%1"=="/rebuild" (
    echo Rebuilding Giulia image...
    docker-compose build
    exit /b 0
)

REM For all other commands, use docker exec to interact with the daemon
REM Map current path to container path
set CURRENT_DIR=%CD%
set DRIVE_LETTER=%CURRENT_DIR:~0,1%
set REST_PATH=%CURRENT_DIR:~2%
set REST_PATH=%REST_PATH:\=/%

REM Calculate relative path from projects root
set CONTAINER_PATH=/projects%REST_PATH%

REM Pass command to daemon via docker exec
if "%1"=="" (
    REM Interactive mode
    docker exec -it %GIULIA_CONTAINER% /app/bin/giulia remote
) else (
    REM Command mode - pass all args
    docker exec -it -e GIULIA_PWD=%CONTAINER_PATH% %GIULIA_CONTAINER% /app/bin/giulia eval "Giulia.Client.main(~w[%*])"
)

endlocal

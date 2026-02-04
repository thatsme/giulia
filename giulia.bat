@echo off
setlocal

:: Save current directory and arguments
set ORIGINAL_DIR=%CD%
set ARGS=%*

:: Change to Giulia project directory (needed for mix)
cd /d "%~dp0"

:: Run the client - pass ORIGINAL_DIR so client knows where user launched from
:: GIULIA_CLIENT_CWD tells the client the real working directory
set GIULIA_CLIENT_CWD=%ORIGINAL_DIR%
elixir -S mix run --no-start -e "Application.ensure_all_started([:jason, :req]); Giulia.Client.main(System.argv())" -- %ARGS%

:: Return to original directory
cd /d "%ORIGINAL_DIR%"

endlocal

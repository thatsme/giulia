@echo off
setlocal

:: Save current directory and arguments
set ORIGINAL_DIR=%CD%
set ARGS=%*

:: Change to Giulia project directory (needed for mix)
cd /d "%~dp0"

:: Run the client - pass ORIGINAL_DIR so client knows where user launched from
:: GIULIA_CLIENT_CWD tells the client the real working directory
:: --no-compile skips recompilation, 2>nul suppresses stderr warnings
set GIULIA_CLIENT_CWD=%ORIGINAL_DIR%
elixir -S mix run --no-start --no-compile -e "Application.ensure_all_started([:jason, :req, :owl]); Giulia.Client.main(System.argv())" -- %ARGS% 2>nul

:: Return to original directory
cd /d "%ORIGINAL_DIR%"

endlocal

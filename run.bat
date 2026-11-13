@echo off
rem Run helper: uses %PYTHON% if set, else the bundled DSH python, else python on PATH.
rem Dependencies (requests / playwright) live in vendor\ next to this file.
setlocal
set "PYTHONPATH=%~dp0vendor"
set "PYTHONIOENCODING=utf-8"

set "PY=%PYTHON%"
if not defined PY if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" set "PY=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if not defined PY if exist "C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" set "PY=C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if not defined PY set "PY=python"

if "%~1"=="" (
    echo Usage:
    echo   run.bat wjx_http_submit.py --id A001 --name ZhangSan [--send]
    echo   run.bat wjx_browser_submit.py --id A001 --name ZhangSan
    echo   run.bat capture_request.py
    exit /b 1
)

"%PY%" %*

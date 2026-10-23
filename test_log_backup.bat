@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT=%~dp0log_backup.bat"
set "TAR=%SystemRoot%\System32\tar.exe"
set "ROOT=%TEMP%\lab1_test_%RANDOM%"
set "LOG=%ROOT%\log"
set "BK=%ROOT%\backup"
set "OUT=%ROOT%\out.txt"
set "FILES=10"
set "FILE_MB=55"
set "THR=1G"
set "LAB1_MAX_COMPRESSION="
set "PASSED=0"
set "FAILED=0"

if not exist "%SCRIPT%" (
    echo Not found: %SCRIPT%
    exit /b 2
)
mkdir "%ROOT%"

echo Testing %SCRIPT%
echo (each test: %FILES% files x %FILE_MB% MB = 550 MB, threshold %THR%)
echo.

call :setup
call :run "%LOG%" 80 "%BK%" %THR%
set "BAD=0"
if not "%CODE%"=="0" set "BAD=1"
call :count "%BK%"
if not "%N%"=="0" set "BAD=1"
call :count "%LOG%"
if not "%N%"=="%FILES%" set "BAD=1"
call :report "1. Below N percent of threshold: no archive created, files untouched"

call :setup
call :run "%LOG%" 30 "%BK%" %THR%
set "BAD=0"
if not "%CODE%"=="0" set "BAD=1"
dir /b "%BK%\log_backup_*.tar.gz" >nul 2>&1
if errorlevel 1 set "BAD=1"
powershell -NoProfile -Command "$s=[int64](Get-ChildItem -LiteralPath $env:LOG -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum; if ($s -le 1GB*30/100) { exit 0 } else { exit 1 }"
if errorlevel 1 set "BAD=1"
call :report "2. Above N percent of threshold: .tar.gz archive created, usage not above 30 percent of threshold"

call :setup
call :run "%LOG%" 30 "%BK%" %THR%
set "BAD=0"
powershell -NoProfile -Command "$a=(Get-ChildItem -LiteralPath $env:BK -Filter *.tar.gz | Select-Object -First 1).FullName; $in=@(& $env:TAR -tf $a | ForEach-Object { $_.Replace('/','\') } | Sort-Object); $ex=@(); foreach ($i in 1..10) { $n='{0:D2}' -f $i; if ($i -eq 4 -or $i -eq 8) { $p='sub\app log_'+$n+'.log' } else { $p='app log_'+$n+'.log' }; $e=Test-Path -LiteralPath (Join-Path $env:LOG $p); if ($i -le 5) { $ex+=$p; if ($e) { exit 1 } } else { if (-not $e) { exit 1 } } }; if ((($ex | Sort-Object) -join '|') -eq ($in -join '|')) { exit 0 } else { exit 1 }"
if errorlevel 1 set "BAD=1"
call :report "3. Archive contains exactly the 5 oldest files, newest files remain"

set "BAD=0"
call :run "%ROOT%\no_such_folder" 50 "%BK%" %THR%
if "%CODE%"=="0" set "BAD=1"
call :run "%LOG%" abc "%BK%" %THR%
if "%CODE%"=="0" set "BAD=1"
call :run "%LOG%" 150 "%BK%" %THR%
if "%CODE%"=="0" set "BAD=1"
call :run "%LOG%" 50 "%BK%" abc
if "%CODE%"=="0" set "BAD=1"
call :run
if "%CODE%"=="0" set "BAD=1"
call :report "4. Invalid arguments: no folder, N is abc or 150, threshold abc, no arguments"

call :setup
set "LAB1_MAX_COMPRESSION=1"
call :run "%LOG%" 30 "%BK%" %THR%
set "LAB1_MAX_COMPRESSION="
set "BAD=0"
set "ARCH="
for %%f in ("%BK%\log_backup_*.tar.lzma") do set "ARCH=%%f"
if not defined ARCH set "BAD=1"
if defined ARCH "%TAR%" -tf "%ARCH%" >nul 2>&1
if errorlevel 1 set "BAD=1"
if exist "%BK%\*.tar.gz" set "BAD=1"
call :report "5. LAB1_MAX_COMPRESSION=1: .tar.lzma archive created and readable"

call :setup
call :run "%LOG%" 30 "%BK%" 2G
set "BAD=0"
if not "%CODE%"=="0" set "BAD=1"
call :count "%BK%"
if not "%N%"=="0" set "BAD=1"
call :count "%LOG%"
if not "%N%"=="%FILES%" set "BAD=1"
call :report "6. Same files, threshold 2G: 550 MB is below 30 percent of it, nothing archived"

set /a TOTAL_TESTS=PASSED+FAILED
echo.
echo Summary: passed %PASSED% of %TOTAL_TESTS%
rmdir /s /q "%ROOT%" 2>nul
if not "%FAILED%"=="0" exit /b 1
exit /b 0

:setup
rmdir /s /q "%LOG%" 2>nul
rmdir /s /q "%BK%" 2>nul
mkdir "%LOG%\sub"
mkdir "%BK%"
powershell -NoProfile -Command "foreach ($i in 1..[int]$env:FILES) { $n='{0:D2}' -f $i; if ($i -eq 4 -or $i -eq 8) { $p=Join-Path $env:LOG ('sub\app log_'+$n+'.log') } else { $p=Join-Path $env:LOG ('app log_'+$n+'.log') }; $fs=[IO.File]::Create($p); $fs.SetLength([int64]$env:FILE_MB*1MB); $fs.Close(); (Get-Item -LiteralPath $p).LastWriteTime=[datetime]('2020-01-'+$n) }"
exit /b 0

:run
call "%SCRIPT%" %1 %2 %3 %4 >"%OUT%" 2>&1
set "CODE=%errorlevel%"
exit /b 0

:count
set "P=%~1"
for /f %%a in ('powershell -NoProfile -Command "(Get-ChildItem -LiteralPath $env:P -Recurse -File -Force | Measure-Object).Count"') do set "N=%%a"
exit /b 0

:report
if "%BAD%"=="0" goto rep_pass
echo   [FAIL] %~1
set /a FAILED+=1
echo          exit code: %CODE%, script output:
type "%OUT%"
exit /b 0
:rep_pass
echo   [PASS] %~1
set /a PASSED+=1
exit /b 0

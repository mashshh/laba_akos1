@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "LOG_DIR=%~1"
set "PERCENT_LIMIT=%~2"
set "BACKUP_DIR=%~3"
set "THRESHOLD_ARG=%~4"
if not defined PERCENT_LIMIT set "PERCENT_LIMIT=70"
if not defined BACKUP_DIR set "BACKUP_DIR=C:\backup"
set "TAR=%SystemRoot%\System32\tar.exe"

if not defined LOG_DIR goto usage
if not exist "%LOG_DIR%\" goto err_dir

powershell -NoProfile -Command "if (($env:PERCENT_LIMIT -match '^[0-9]{1,3}$') -and ([int]$env:PERCENT_LIMIT -ge 1) -and ([int]$env:PERCENT_LIMIT -le 100)) { exit 0 } else { exit 1 }"
if errorlevel 1 goto err_percent

set "TAR_FLAG=-z"
set "EXT=tar.gz"
set "ALGO=gzip"
if "%LAB1_MAX_COMPRESSION%"=="1" set "TAR_FLAG=--lzma"
if "%LAB1_MAX_COMPRESSION%"=="1" set "EXT=tar.lzma"
if "%LAB1_MAX_COMPRESSION%"=="1" set "ALGO=lzma"

set "THRESHOLD_BYTES=0"
if not defined THRESHOLD_ARG goto default_threshold
for /f "usebackq" %%a in (`powershell -NoProfile -Command "if ($env:THRESHOLD_ARG -match '^([0-9]+)([KkMmGg]?)$') { $n=[int64]$matches[1]; switch ($matches[2].ToUpper()) { 'K' { $n*=1KB } 'M' { $n*=1MB } 'G' { $n*=1GB } }; Write-Output $n } else { Write-Output 0 }"`) do set "THRESHOLD_BYTES=%%a"
goto check_threshold
:default_threshold
for /f "usebackq" %%a in (`powershell -NoProfile -Command "(New-Object System.IO.DriveInfo((Get-Item -LiteralPath $env:LOG_DIR).PSDrive.Name)).TotalSize"`) do set "THRESHOLD_BYTES=%%a"
:check_threshold
powershell -NoProfile -Command "if (($env:THRESHOLD_BYTES -match '^[0-9]+$') -and ([int64]$env:THRESHOLD_BYTES -gt 0)) { exit 0 } else { exit 1 }"
if errorlevel 1 goto err_threshold

call :stats
echo Folder:       %LOG_DIR%
echo Threshold:    %THRESHOLD_MB% MB
echo Folder usage: %PERCENT%%% of threshold (%SIZE_MB% MB of %THRESHOLD_MB% MB), allowed: %PERCENT_LIMIT%%%

if "%TOFREE%"=="0" goto fine
echo Need to free: %TOFREE_MB% MB

set "LIST=%TEMP%\lab1_list_%RANDOM%.txt"
set "COUNT=0"
set "FREED_MB=0"
for /f "usebackq tokens=1,2" %%a in (`powershell -NoProfile -Command "$base=(Resolve-Path -LiteralPath $env:LOG_DIR).ProviderPath.TrimEnd('\'); $need=[int64]$env:TOFREE; $sum=[int64]0; $rel=New-Object System.Collections.Generic.List[string]; foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object LastWriteTimeUtc)) { if ($sum -ge $need) { break }; $rel.Add($f.FullName.Substring($base.Length + 1)); $sum += $f.Length }; [IO.File]::WriteAllLines($env:LIST, $rel, (New-Object System.Text.UTF8Encoding($false))); Write-Output ($rel.Count.ToString() + ' ' + [int64]($sum/1MB))"`) do (
    set "COUNT=%%a"
    set "FREED_MB=%%b"
)
if "%COUNT%"=="0" goto err_empty

if not exist "%BACKUP_DIR%\" mkdir "%BACKUP_DIR%"
if not exist "%BACKUP_DIR%\" goto err_mkdir
for /f %%a in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%a"
set "ARCHIVE=%BACKUP_DIR%\log_backup_%STAMP%.%EXT%"

echo Archiving files: %COUNT% (%FREED_MB% MB), algorithm: %ALGO%
"%TAR%" %TAR_FLAG% -cf "%ARCHIVE%" -C "%LOG_DIR%" -T "%LIST%"
if errorlevel 1 goto err_tar

powershell -NoProfile -Command "Get-Content -LiteralPath $env:LIST -Encoding UTF8 | ForEach-Object { Remove-Item -LiteralPath (Join-Path $env:LOG_DIR $_) -Force }"
del "%LIST%" 2>nul

call :stats
echo Archive:      %ARCHIVE%
echo Done. Folder usage is now: %PERCENT%%% of threshold
if not "%TOFREE%"=="0" >&2 echo Warning: limit not reached - no more files left to archive.
exit /b 0

:fine
echo Usage is within the limit, nothing to archive.
exit /b 0

:stats
for /f "usebackq tokens=1-5" %%a in (`powershell -NoProfile -Command "$s=[int64](Get-ChildItem -LiteralPath $env:LOG_DIR -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum; $t=[int64]$env:THRESHOLD_BYTES; $g=[int64][math]::Floor($t*[int64]$env:PERCENT_LIMIT/100); $f=[int64][math]::Max(0,$s-$g); $p=[math]::Round($s*100/$t,1).ToString([cultureinfo]::InvariantCulture); Write-Output (([int64]($s/1MB)),([int64]($t/1MB)),$p,$f,([int64]($f/1MB)) -join ' ')"`) do (
    set "SIZE_MB=%%a"
    set "THRESHOLD_MB=%%b"
    set "PERCENT=%%c"
    set "TOFREE=%%d"
    set "TOFREE_MB=%%e"
)
exit /b 0

:usage
>&2 echo Usage: %~nx0 ^<log_dir^> [N_percent=70] [backup_dir=C:\backup] [threshold=partition size]
exit /b 1

:err_dir
>&2 echo Error: "%LOG_DIR%" is not a directory
exit /b 1

:err_percent
>&2 echo Error: N must be an integer from 1 to 100
exit /b 1

:err_threshold
>&2 echo Error: threshold must be a positive size such as 500M, 1G or a number of bytes
exit /b 1

:err_empty
>&2 echo No files to archive in the folder.
del "%LIST%" 2>nul
exit /b 1

:err_mkdir
>&2 echo Error: cannot create the backup folder "%BACKUP_DIR%"
del "%LIST%" 2>nul
exit /b 1

:err_tar
>&2 echo Error: tar failed to create the archive, files in the log folder were NOT deleted.
del "%ARCHIVE%" 2>nul
del "%LIST%" 2>nul
exit /b 1

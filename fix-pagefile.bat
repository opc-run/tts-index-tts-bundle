@echo off
rem ============================================================
rem  IndexTTS bundle - Expand Windows page file (virtual memory)
rem  to 16-32 GB. Fixes:
rem    - "os error 1455" / "Not enough memory"
rem    - fake "CUDA out of memory" while nvidia-smi shows free VRAM
rem  Usage: double-click this file (auto requests Administrator).
rem ============================================================
title fix-pagefile (IndexTTS)

rem ---- Re-launch as Administrator if not already ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Expanding page file to 16384-32768 MB ...

powershell -NoProfile -ExecutionPolicy Bypass -Command "$cs = Get-CimInstance Win32_ComputerSystem; if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }; Write-Host '[1/3] System-managed pagefile disabled.' } else { Write-Host '[1/3] Already manually managed.' }; $pf = Get-CimInstance Win32_PageFileSetting; if ($pf) { $pf | Set-CimInstance -Property @{ InitialSize = 16384; MaximumSize = 32768 }; Write-Host '[2/3] Existing pagefile resized to 16-32 GB.' } else { $os = Get-CimInstance Win32_OperatingSystem; $name = $os.SystemDrive + '\pagefile.sys'; New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $name; InitialSize = 16384; MaximumSize = 32768 }; Write-Host ('[2/3] Created pagefile ' + $name + ' (16-32 GB).') }"

echo.
echo Verifying ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$pf = Get-CimInstance Win32_PageFileSetting; if ($pf) { Write-Host ('Current: Initial=' + $pf.InitialSize + ' MB, Max=' + $pf.MaximumSize + ' MB'); if ($pf.InitialSize -ge 16384 -and $pf.MaximumSize -ge 32768) { Write-Host 'OK: pagefile is 16-32 GB.' } else { Write-Host 'NOT effective yet: reboot once and verify again.' } } else { Write-Host 'No pagefile setting found: reboot once and verify again.' }"

echo.
pause

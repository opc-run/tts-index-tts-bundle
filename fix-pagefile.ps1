#Requires -Version 5.1
<#
.SYNOPSIS
  IndexTTS bundle - Expand Windows page file (virtual memory) to 16-32 GB.
  Fixes:
    - "os error 1455" / "Not enough memory"
    - fake "CUDA out of memory" while nvidia-smi shows free VRAM
  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-pagefile.ps1
  Auto re-launches as Administrator if not already elevated.
#>

# ---- Re-launch as Administrator if not already ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..."
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -Verb RunAs
    exit
}

Write-Host "Expanding page file to 16384-32768 MB ..."

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.AutomaticManagedPagefile) {
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
    Write-Host "[1/3] System-managed pagefile disabled."
} else {
    Write-Host "[1/3] Already manually managed."
}

$pf = Get-CimInstance Win32_PageFileSetting
if ($pf) {
    $pf | Set-CimInstance -Property @{ InitialSize = 16384; MaximumSize = 32768 }
    Write-Host "[2/3] Existing pagefile resized to 16-32 GB."
} else {
    $os = Get-CimInstance Win32_OperatingSystem
    $name = $os.SystemDrive + '\pagefile.sys'
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $name; InitialSize = 16384; MaximumSize = 32768 }
    Write-Host "[2/3] Created pagefile $name (16-32 GB)."
}

Write-Host ""
Write-Host "Verifying ..."
$pf = Get-CimInstance Win32_PageFileSetting
if ($pf) {
    Write-Host ("Current: Initial=" + $pf.InitialSize + " MB, Max=" + $pf.MaximumSize + " MB")
    if ($pf.InitialSize -ge 16384 -and $pf.MaximumSize -ge 32768) {
        Write-Host "OK: pagefile is 16-32 GB."
    } else {
        Write-Host "NOT effective yet: reboot once and verify again."
    }
} else {
    Write-Host "No pagefile setting found: reboot once and verify again."
}

Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

#requires -Version 5.1
<#
  停止 IndexTTS-2.5 Web UI（Windows）。

  用法：
    .\stop-webui.ps1                      # 停止本项目 Web UI（任意端口）
    .\stop-webui.ps1 -Port 7861           # 只停止 7861 端口的实例
    .\stop-webui.ps1 -All                 # 也匹配本项目目录之外的 webui.py
    .\stop-webui.ps1 -Id 16444,19040      # 停止指定 PID

  进程退出后，还会清理 hf_cache 下残留的 ModelScope ._____temp 目录
  （Web UI 锁定期间无法删除的重复文件，约 4.6 GB）。
#>
param(
    [int]$Port = 7860,
    [switch]$All,
    [int[]]$Id
)

$ErrorActionPreference = "Stop"

$ROOT = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# 与 start-webui.ps1 一致，尊重自定义安装根目录 / checkpoints 目录。
$CKPT = Join-Path $ROOT "checkpoints"
$stateFile = Join-Path $ROOT ".install-state.json"
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($st.checkpointsDir -and (Test-Path $st.checkpointsDir)) { $CKPT = $st.checkpointsDir }
    } catch { }
}

$targets = @{}

if ($Id.Count -gt 0) {
    # 显式 -Id 始终优先。
    foreach ($i in $Id) { $targets[[int]$i] = "explicit -Id" }
} else {
    # 匹配本项目的 webui.py 进程——即使它们没绑上端口
    # （例如模型加载中卡住的 Web UI 仍持有文件锁）。
    # -Port 收窄到指定端口；-All 也会匹配本项目目录之外的 webui.py。
    $proj = $ROOT.Replace('\', '/')
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'webui\.py' } |
        ForEach-Object {
            $inProj   = $_.CommandLine -match [regex]::Escape($proj)
            $portFlag = $_.CommandLine -match "--port[ =]$Port(?: |\Z)"
            if ($All -or $inProj -or $portFlag) {
                $how = if ($inProj) { "webui.py 进程" } else { "webui.py 进程（端口 $Port）" }
                if (-not $targets.ContainsKey([int]$_.ProcessId)) { $targets[[int]$_.ProcessId] = $how }
            }
        }

    # 实际监听目标端口的进程始终优先。
    try {
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            ForEach-Object { if (-not $targets.ContainsKey([int]$_.OwningProcess)) { $targets[[int]$_.OwningProcess] = "正在监听端口 $Port" } }
    } catch { }
}

if ($targets.Count -eq 0) {
    Write-Host "在端口 $Port 上未找到 Web UI 进程。" -ForegroundColor Yellow
    Write-Host "可用 -All 匹配任意 webui.py，或用 -Id <pid> 指定目标进程。" -ForegroundColor DarkGray
    exit 1
}

$stopped = 0
foreach ($k in @($targets.Keys)) {
    $p = Get-Process -Id $k -ErrorAction SilentlyContinue
    if (-not $p) {
        Write-Host "  [skip] PID $k 未在运行（$($targets[$k])）" -ForegroundColor DarkGray
        continue
    }
    Write-Host "  正在停止 PID $k（$($p.ProcessName)）- $($targets[$k])" -ForegroundColor Cyan
    Stop-Process -Id $k -Force
    Start-Sleep -Milliseconds 400
    if (Get-Process -Id $k -ErrorAction SilentlyContinue) {
        Write-Host "  [WARN] PID $k 仍在运行" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK]   PID $k 已停止" -ForegroundColor Green
        $stopped++
    }
}

# 释放磁盘：删除残留的 ModelScope ._____temp 目录（中断下载留下的重复文件）。
# 之前被上面的 Web UI 进程锁定，现在可以删除了。
$hfCache = Join-Path $CKPT "hf_cache"
if (Test-Path $hfCache) {
    $temps = @(Get-ChildItem -Path $hfCache -Directory -Filter "._____temp" -Recurse -ErrorAction SilentlyContinue)
    if ($temps.Count -gt 0) {
        Write-Host ""
        Write-Host "正在清理 $hfCache 下残留的 ModelScope 临时目录 ..." -ForegroundColor DarkGray
    }
    foreach ($t in $temps) {
        Write-Host "  删除 $($t.FullName)" -ForegroundColor DarkGray
        Remove-Item $t.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($stopped -gt 0) {
    Write-Host "完成。已停止 $stopped 个 Web UI 进程。现在可以重新运行 start-webui.bat。" -ForegroundColor Green
} else {
    Write-Host "没有进程被停止。" -ForegroundColor Yellow
}
exit 0

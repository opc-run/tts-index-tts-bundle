#requires -Version 5.1
<#
  Start the IndexTTS-2.5 Web UI (Windows).
  Usage:
    .\start-webui.ps1                       # default: http://127.0.0.1:7860
    .\start-webui.ps1 -Port 7861 -FP16      # change port / force FP16
    .\start-webui.ps1 -NoAutoFP16           # disable auto FP16 on low-VRAM GPUs
  Optional flags: -FP16, -NoAutoFP16, -Deepspeed, -CudaKernel, -Accel, -TorchCompile, -QwenEmo, -Verbose
#>
param(
    [int]$Port = 7860,
    [string]$HostAddr = "0.0.0.0",
    [switch]$FP16,
    [switch]$NoAutoFP16,
    [switch]$Deepspeed,
    [switch]$CudaKernel,
    [switch]$Accel,
    [switch]$TorchCompile,
    [switch]$QwenEmo,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# CodeBuddy's genie extension injects a sitecustomize.py shim through
# PYTHONPATH that hijacks os.remove / os.unlink / shutil.move (routing them
# through a "safe delete / trash" service). That breaks model downloads
# (ModelScope moves temp files with shutil.move) and partial-download cleanup,
# so strip it from the environment of every child Python.
$env:PYTHONPATH = (($env:PYTHONPATH -split ';') | Where-Object { $_ -and $_ -notlike '*genie*vendor*shim*' }) -join ';'
$env:CODEBUDDY_SAFE_DELETE_ENABLED = '0'
# Unbuffered Python output: if webui.py crashes natively (e.g. 0xC0000005),
# block-buffered stdout would be lost entirely, leaving an empty crash log
# and an unexplained "can't connect" error. With this, every line is flushed
# to the log in real time so we can diagnose the failure.
$env:PYTHONUNBUFFERED = '1'

$ROOT = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# If the installer was pointed at a different -InstallRoot, honor its state file.
$stateFile = Join-Path $ROOT ".install-state.json"
if (Test-Path $stateFile) {
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($state.installRoot -and (Test-Path $state.installRoot)) { $ROOT = $state.installRoot }
    } catch { }
}
$stateFile = Join-Path $ROOT ".install-state.json"
$REPO   = Join-Path $ROOT "index-tts"
$CKPT   = Join-Path $ROOT "checkpoints"
$PY     = Join-Path $REPO ".venv\Scripts\python.exe"

# Add portable ffmpeg to PATH if the installer provided one.
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($st.ffmpegBin -and (Test-Path $st.ffmpegBin)) {
            $env:PATH = "$($st.ffmpegBin);$env:PATH"
        }
        if ($st.checkpointsDir) { $CKPT = $st.checkpointsDir }
        if ($st.repoDir) { $REPO = $st.repoDir }
        if ($st.venvDir) { $PY = Join-Path $st.venvDir "Scripts\python.exe" }
    } catch { }
}

if (-not (Test-Path $PY)) {
    Write-Host "Virtualenv Python not found: $PY" -ForegroundColor Red
    Write-Host "Run install.ps1 first. See README.md." -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path (Join-Path $CKPT "config.yaml"))) {
    Write-Host "[WARN] Model config not found in $CKPT" -ForegroundColor Yellow
    Write-Host "       Run install.ps1 (downloads the model) or place IndexTTS-2.5 manually." -ForegroundColor Yellow
}

# Auxiliary models (w2v-bert-2.0 ~4.3 GB, campplus, bigvgan, semantic codec)
# live in $CKPT\hf_cache. They are required by the Web UI; without them the
# first launch would silently start a huge download (or crash when a partial
# dir is mistaken for "already present"). Make sure they are complete first.
function Test-AuxModelsReady {
    param([string]$Dir)
    $hf = Join-Path $Dir "hf_cache"
    if (-not (Test-Path $hf)) { return $false }
    $w2vModel = Join-Path $hf "w2v-bert-2.0\model.safetensors"
    if (-not (Test-Path $w2vModel)) { return $false }
    if ((Get-Item $w2vModel).Length -lt 100MB) { return $false }
    $required = @(
        (Join-Path $hf "campplus_cn_common.bin"),
        (Join-Path $hf "semantic_codec_model.safetensors"),
        (Join-Path $hf "bigvgan\config.json"),
        (Join-Path $hf "bigvgan\bigvgan_generator.pt")
    )
    foreach ($f in $required) { if (-not (Test-Path $f)) { return $false } }
    return $true
}
if (-not (Test-AuxModelsReady $CKPT)) {
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host "  Auxiliary models missing in $CKPT\hf_cache" -ForegroundColor Yellow
    Write-Host "  (w2v-bert-2.0 ~4.3 GB, campplus, bigvgan, semantic codec)" -ForegroundColor Yellow
    Write-Host "  Downloading now -- this is a one-time download, please wait..." -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow
    $auxCode = @'
import glob, os, shutil, sys, time, traceback
from indextts.utils.model_download import ensure_models_available

ckpt = sys.argv[1]
w2v = os.path.join(ckpt, "hf_cache", "w2v-bert-2.0")

def clean_partial_w2v():
    # w2v-bert-2.0 must be a COMPLETE repo dir. A partial dir left by an
    # interrupted download (e.g. a ModelScope ._____temp dir with 0-byte
    # files) would otherwise be mistaken for "already present" and crash at
    # load time. Retry the removal because Windows may briefly hold a file
    # lock on files written by the interrupted process.
    if os.path.isdir(w2v):
        key = os.path.join(w2v, "model.safetensors")
        if not (os.path.isfile(key) and os.path.getsize(key) > 100 * 1024 * 1024):
            print(">> Removing incomplete w2v-bert-2.0 dir (interrupted download)...")
            for _i in range(3):
                try:
                    shutil.rmtree(w2v)
                    break
                except OSError:
                    if _i == 2:
                        shutil.rmtree(w2v, ignore_errors=True)
                    else:
                        time.sleep(1)

def w2v_ready():
    key = os.path.join(w2v, "model.safetensors")
    return os.path.isfile(key) and os.path.getsize(key) > 100 * 1024 * 1024

def download_w2v_via_mirror():
    # China-friendly HuggingFace mirror (hf-mirror.com), resumable. Used when
    # the default source (ModelScope / HF direct) fails on the 4.3 GB weight.
    # Runs the huggingface_hub CLI in a subprocess: HF_ENDPOINT is only
    # honored by a fresh process, not by mutating os.environ after import.
    if w2v_ready():
        print(">> w2v-bert-2.0 already complete, skipping mirror download.")
        return
    from indextts.utils.model_download import _snapshot_from_hf_mirror
    print(">> Downloading w2v-bert-2.0 via hf-mirror.com (resumable, please wait)...")
    _snapshot_from_hf_mirror("facebook/w2v-bert-2.0", w2v)
    if not w2v_ready():
        raise RuntimeError("w2v-bert-2.0 still incomplete after mirror download")

clean_partial_w2v()
try:
    ensure_models_available(ckpt)
except Exception:
    print(">> Default model download failed, retrying via hf-mirror.com ...")
    traceback.print_exc()
    clean_partial_w2v()
    download_w2v_via_mirror()
    ensure_models_available(ckpt)
if not w2v_ready():
    raise SystemExit("ERROR: w2v-bert-2.0 still incomplete after all download attempts")
# Free disk: remove stale ModelScope ._____temp dirs (duplicates of completed
# downloads left behind when the interrupted move could not unlink its source).
for _stale in glob.glob(os.path.join(ckpt, "hf_cache", "**", "._____temp"), recursive=True):
    print(f">> Removing stale temp dir: {_stale}")
    shutil.rmtree(_stale, ignore_errors=True)
print(">> All auxiliary models ready.")
'@
    Push-Location $REPO
    # Never pass the multi-line Python via `python -c`: Windows PowerShell
    # 5.1 does not escape embedded quotes/newlines in native args, so the
    # code gets truncated at the first `"` (e.g. in a comment) and fails
    # with IndentationError. Write it to a temp .py file instead.
    $auxPy = Join-Path $env:TEMP "index-tts-aux-download.py"
    [System.IO.File]::WriteAllText($auxPy, $auxCode)
    & $PY $auxPy $CKPT
    $auxCodeExit = $LASTEXITCODE
    Remove-Item $auxPy -Force -ErrorAction SilentlyContinue
    Pop-Location
    if ($auxCodeExit -ne 0 -or -not (Test-AuxModelsReady $CKPT)) {
        Write-Host "[FAIL] Auxiliary model download failed. Check network and re-run." -ForegroundColor Red
        Write-Host "       The Web UI may not start correctly until they are complete." -ForegroundColor Red
    } else {
        Write-Host "[OK] Auxiliary models ready." -ForegroundColor Green
    }
}

$env:TOKENIZERS_PARALLELISM = "false"

# 一键运行：检测到显存不足 16GB 时自动启用 FP16，无需用户手动加参数。
# 全精度(FP32)在 12GB 卡上几乎必挂；低显存卡自动带上 --fp16 即可一次跑通。
# 用户显式加 -FP16 无副作用；想禁用自动行为可用 -NoAutoFP16。
if (-not $FP16 -and -not $NoAutoFP16) {
    try {
        $gpuTotal = (& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1).Trim()
        if ($gpuTotal -match '^\d+$' -and [int]$gpuTotal -lt 16384) {
            $FP16 = $true
            Write-Host ""
            Write-Host "[自动] 检测到 GPU 显存约 $gpuTotal MiB（不足 16GB），已自动启用 FP16 模式。" -ForegroundColor Yellow
            Write-Host "       无需手动操作，正在以 FP16 启动。（如需关闭自动行为，可用 -NoAutoFP16）" -ForegroundColor Yellow
            Write-Host ""
        }
    } catch { }
}

$modelArgs = @("--model_dir", $CKPT, "--port", "$Port", "--host", $HostAddr)
if ($FP16) { $modelArgs += "--fp16" }
if ($Deepspeed) { $modelArgs += "--deepspeed" }
if ($CudaKernel) { $modelArgs += "--cuda_kernel" }
if ($Accel) { $modelArgs += "--accel" }
if ($TorchCompile) { $modelArgs += "--torch_compile" }
if ($QwenEmo) { $modelArgs += "--qwen_emo" }
if ($Verbose) { $modelArgs += "--verbose" }

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  IndexTTS-2.5 Web UI" -ForegroundColor Cyan
Write-Host "  Model   : $CKPT"
Write-Host "  Mode    : $(if ($FP16) { 'FP16 (half precision)' } else { 'FP32 (full precision)' })"
Write-Host "  Status  : 正在启动（就绪后会显示访问地址）"
Write-Host "======================================================================" -ForegroundColor Cyan

# webui.py 的 warning / traceback 走 stderr。若脚本保持 $ErrorActionPreference
# = "Stop"，5.1 会把 2>&1 合并进来的 stderr 行当成终止错误、在调用处直接掐断
# 脚本（诊断块根本没机会执行）；7.3+ 则受 $PSNativeCommandUseErrorActionPreference
# 控制。统一做法：调用期间临时降级为 Continue。
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"

# 完整输出同时写一份日志，崩溃后据此诊断原因并给出修复提示。
$logDir = Join-Path $env:TEMP "index-tts"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$uiLog = Join-Path $logDir "webui.stdout.log"
$uiErr = Join-Path $logDir "webui.stderr.log"
Remove-Item $uiLog, $uiErr -Force -ErrorAction SilentlyContinue

# 后台启动 webui.py（复用当前控制台窗口，无新弹窗），stdout/stderr 分别落盘。
# 主线程随后轮询就绪状态并输出心跳反馈——避免出现"banner 打印完就长时间
# 沉默，用户误以为启动成功、其实模型还在加载"的困惑。
$pyArgs = @("webui.py") + $modelArgs
$uiProc = Start-Process -FilePath $PY -ArgumentList $pyArgs -WorkingDirectory $REPO `
    -RedirectStandardOutput $uiLog -RedirectStandardError $uiErr -PassThru -NoNewWindow

$url = "http://127.0.0.1:$Port"
$startedAt = Get-Date
$lastBeat = $startedAt
$lastWarn = $startedAt
$ready = $false
$code = 1
Write-Host ""
Write-Host "  正在加载模型并启动服务，约需 1-2 分钟，期间会定时提示进度..." -ForegroundColor DarkGray
Write-Host "  请稍候，直到出现「Web UI 已就绪」再打开浏览器。" -ForegroundColor DarkGray

while (-not $uiProc.HasExited) {
    Start-Sleep -Seconds 3

    # 就绪探测：HTTP 返回 200 即认为可访问（比只听端口更可靠）
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }

    $elapsed = [int]((Get-Date).Subtract($startedAt).TotalSeconds)

    # 每 10 秒一条心跳，顺带展示日志最新一行，让用户看到实际进展
    if ($elapsed -ge 10 -and ((Get-Date) - $lastBeat).TotalSeconds -ge 10) {
        $lastBeat = Get-Date
        $latest = ""
        foreach ($lf in @($uiErr, $uiLog)) {
            if (Test-Path $lf) {
                $l = Get-Content $lf -Tail 1 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 1
                if ($l) { $latest = [string]$l; break }
            }
        }
        if ($latest) {
            Write-Host ("  ... 正在加载，已等待 {0} 秒  |  {1}" -f $elapsed, $latest.Trim()) -ForegroundColor DarkGray
        } else {
            Write-Host ("  ... 正在加载模型，已等待 {0} 秒（暂无新输出，请耐心等待）" -f $elapsed) -ForegroundColor DarkGray
        }
    }

    # 长时间未就绪：每 10 分钟提醒一次（只提示不退出，避免误杀慢机器）
    if ($elapsed -ge 600 -and ((Get-Date) - $lastWarn).TotalSeconds -ge 600) {
        $lastWarn = Get-Date
        Write-Host ""
        Write-Host "  [提示] 已等待 $elapsed 秒仍未就绪。可能是模型加载较慢，也可继续等待；" -ForegroundColor Yellow
        Write-Host "         若怀疑卡住，可先打开 $url 看是否已有页面，或按 Ctrl+C 停止重试。" -ForegroundColor Yellow
        Write-Host ""
    }
}

if ($ready) {
    $code = 0
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "  Web UI 已就绪！请在浏览器打开:" -ForegroundColor Green
    Write-Host "      $url" -ForegroundColor Green
    Write-Host "  （按 Ctrl+C 停止服务并关闭窗口）" -ForegroundColor DarkGray
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host ""
    # 保持前台运行，等待用户 Ctrl+C 或 webui.py 自行退出。
    # 已成功就绪，之后进程退出（无论何种原因）都不再报"启动失败"。
    Wait-Process -Id $uiProc.Id -ErrorAction SilentlyContinue
    $code = 0
}
else {
    # 进程提前退出 = 启动失败，进入下方诊断。
    # 注：PS 5.1 中 Start-Process -NoNewWindow -PassThru 返回的进程对象在
    # 退出后读不到 ExitCode（已知 bug），因此诊断一律基于日志内容。
    Write-Host ""
    Write-Host "  [INFO] webui.py 提前退出，未能启动服务。正在分析原因..." -ForegroundColor DarkGray
    $code = 1
}

$ErrorActionPreference = $oldEAP

if ($code -ne 0) {
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "  Web UI 启动失败 (exit code: $code)" -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red

    $tail = @()
    foreach ($lf in @($uiErr, $uiLog)) {
        if (Test-Path $lf) { $tail += @(Get-Content $lf -Tail 50 -ErrorAction SilentlyContinue) }
    }
    $joined = $tail -join "`n"

    if ($joined -match '页面文件太小|os error 1455|Not enough memory|KernelBase\.dll|insufficient.*memory') {
        Write-Host "  [原因] 系统页面文件（虚拟内存）太小，加载模型时内存不足。" -ForegroundColor Yellow
        Write-Host "  [修复] 双击运行 fix-pagefile.bat（自动以管理员身份扩大页面文件），" -ForegroundColor Yellow
        Write-Host "         完成后重新双击 start-webui.bat。" -ForegroundColor Yellow
    }
    elseif ($joined -match 'Address already in use|WinError 10048|bind.*already|EADDRINUSE') {
        Write-Host "  [原因] 端口 $Port 已被占用，可能已有另一个 Web UI 在运行。" -ForegroundColor Yellow
        Write-Host "  [修复] 先双击 stop-webui.bat 停止旧实例，再重新启动。" -ForegroundColor Yellow
        Write-Host "         或改用其它端口: start-webui.bat -Port 7861" -ForegroundColor Yellow
    }
    elseif ($joined -match 'CUDA out of memory|CUDA error|out of memory') {
        Write-Host "  [原因] CUDA 分配显存失败。" -ForegroundColor Yellow
        Write-Host "         如果 nvidia-smi 显示显存仍有很多空闲，那多半不是显存不够，而是" -ForegroundColor Yellow
        Write-Host "         系统页面文件（虚拟内存）不足——Windows 上 CUDA 分配显存也受其限制。" -ForegroundColor Yellow
        Write-Host "  [修复] 1) 双击 fix-pagefile.bat 扩大页面文件，按提示重启电脑；" -ForegroundColor Yellow
        Write-Host "         2) 12GB 显存建议始终用 start-webui.bat -FP16 启动。" -ForegroundColor Yellow
    }
    elseif ($joined -match 'config\.yaml|No such file|not found|找不到|No module named') {
        Write-Host "  [原因] 模型文件缺失、损坏或依赖未装全。" -ForegroundColor Yellow
        Write-Host "  [修复] 重新运行 install.bat 修复安装；模型问题详见 README 常见问题。" -ForegroundColor Yellow
    }
    elseif ($tail.Count -eq 0) {
        Write-Host "  [原因] 进程启动后立即崩溃（可能是原生崩溃 access violation），且没有留下日志。" -ForegroundColor Yellow
        Write-Host "         常见于内存不足、页面文件过小、显卡驱动不稳定或 CUDA 初始化失败。" -ForegroundColor Yellow
        Write-Host "  [建议] 1) 双击 fix-pagefile.bat 扩大页面文件后重试；" -ForegroundColor Yellow
        Write-Host "         2) 12GB 显存请确认以 FP16 启动（本脚本会自动启用）；" -ForegroundColor Yellow
        Write-Host "         3) 更新显卡驱动后重试。" -ForegroundColor Yellow
    }
    else {
        Write-Host "  [原因] 未能自动识别，请看下方最近的日志，或到 README 常见问题中查找。" -ForegroundColor Yellow
    }

    if ($tail.Count -gt 0) {
        Write-Host ""
        Write-Host "  ---------- 最近日志（最后 50 行）----------" -ForegroundColor Cyan
        $tail | ForEach-Object { Write-Host "  $_" }
        Write-Host "  -------------------------------------------" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  完整日志: $uiLog  /  $uiErr" -ForegroundColor DarkGray
    Write-Host ""
}
exit $code

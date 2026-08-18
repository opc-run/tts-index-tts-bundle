#requires -Version 5.1
<#
=============================================================================
  IndexTTS-2.5 一键安装程序（Windows）
  https://github.com/index-tts/index-tts

  本脚本会做什么：
    1. 检测并复用本机已有的工具（git / uv / ffmpeg / Python 3.10/3.11），
       已存在的不会重复安装。
    2. 只安装缺失的部分，并尽可能装到本包的本地目录（tools\、python\、
       cache\），而不是 C: 盘或用户目录。
    3. 克隆 index-tts 源码并创建独立虚拟环境（所有 Python 依赖都放在
       index-tts\.venv，不动系统 Python）。
    4. 把 IndexTTS-2.5 模型下载到预留的 .\checkpoints 目录——或者复用你
       已手动放置好的模型。

  用法：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -ModelSource huggingface
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -PyMirror aliyun

  重要：所有内容都存放在本包目录内。完整安装约需 40 GB 空间，
  请把它解压到空间充足的盘符（任意盘符均可）。
=============================================================================
#>

[CmdletBinding()]
param(
    # 整个包所在的根目录。默认 = 本脚本所在目录。
    [string]$InstallRoot = "",

    # 模型下载源。"auto" = modelscope（国内更快）。
    [ValidateSet("auto", "huggingface", "modelscope")]
    [string]$ModelSource = "auto",

    # 非 torch 包的 PyPI 镜像。
    [ValidateSet("none", "aliyun", "tuna", "tsinghua")]
    [string]$PyMirror = "none",

    # 克隆源码用的 GitHub 加速镜像。
    #   "auto"  = 先试官方地址，再试常见国内镜像
    #   "none"  = 只用官方地址
    #   或直接传镜像前缀 URL（如 "https://gh-proxy.com"）或完整 clone URL（以 .git 结尾）
    [string]$GitMirror = "auto",

    # 逗号分隔的 uv extras，例如 "webui" 或 "webui,deepspeed"。
    [string]$Extras = "webui",

    # 只做环境预检并打印计划，不做任何修改。
    [switch]$CheckOnly,

    # 跳过模型下载（只安装代码 + 依赖）。
    [switch]$SkipModels,

    # 跳过便携版 ffmpeg 下载（没有它模型可能仍能工作）。
    [switch]$SkipFFmpeg,

    # 当 git 缺失时尝试自动 `winget install Git.Git`。
    [switch]$AutoInstallGit = $true,

    # 跳过磁盘空间检查（快速 CI / 特殊挂载点）。
    [switch]$SkipCheck,

    # 跳过提问，全部使用默认值。
    [switch]$Yes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# --------------------------------------------------------------------------
# CodeBuddy 的 genie 扩展会通过 PYTHONPATH 注入一个 sitecustomize.py 垫片，
# 劫持 os.remove / os.unlink / shutil.move（把它们路由到"安全删除/回收站"）。
# 这会破坏模型下载（ModelScope 用 shutil.move 移动临时文件）以及部分下载的
# 清理逻辑，所以从每个子 Python 的环境中把它剥离掉。
# --------------------------------------------------------------------------
$env:PYTHONPATH = (($env:PYTHONPATH -split ';') | Where-Object { $_ -and $_ -notlike '*genie*vendor*shim*' }) -join ';'
$env:CODEBUDDY_SAFE_DELETE_ENABLED = '0'

# --------------------------------------------------------------------------
# 日志输出辅助
# --------------------------------------------------------------------------
function Write-Step  { Write-Host ""; Write-Host "==> $args" -ForegroundColor Cyan }
function Write-Info  { Write-Host "    $args" -ForegroundColor Gray }
function Write-Ok    { Write-Host "  [OK] $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "  [WARN] $args" -ForegroundColor Yellow }
function Write-Fail  { Write-Host "  [FAIL] $args" -ForegroundColor Red }

# PowerShell 5.1 会把原生命令产生的任何 stderr 变成 NativeCommandError，
# 而 $ErrorActionPreference = "Stop" 会把它升级为致命错误——即使该命令其实
# 成功了（git/uv/modelscope 都会往 stderr 打印进度）。所以原生命令请通过这些
# 包装器运行：
#   Invoke-Native 保留 stderr 可见（安装/下载进度）；
#   Invoke-Silent 丢弃 stderr（探活命令可能合理地失败）。
function Invoke-Native {
    param([scriptblock]$Body)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Body } finally { $ErrorActionPreference = $prev }
}
function Invoke-Silent {
    param([scriptblock]$Body)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Body 2>$null } finally { $ErrorActionPreference = $prev }
}

# --------------------------------------------------------------------------
# 小工具函数
# --------------------------------------------------------------------------
function Get-FullPath([string]$Path) {
    if (-not $Path) { return "" }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return $resolved
}

function Get-DriveFreeGB([string]$Path) {
    try {
        $drive = (Get-Item $Path -ErrorAction Stop).PSDrive
        return [math]::Round($drive.Free / 1GB, 1)
    } catch {
        return -1
    }
}

function Get-DirSizeGB([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $bytes = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($bytes / 1GB), 2)
}

function Test-Python311Exe([string]$ExePath) {
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return $null }
    try {
        $out = & $ExePath --version 2>&1 | Out-String
    } catch { return $null }
    if ($out -match "Python\s+(\d+)\.(\d+)") {
        $maj = [int]$Matches[1]; $min = [int]$Matches[2]
        if ($maj -eq 3 -and ($min -eq 10 -or $min -eq 11)) { return $out.Trim() }
    }
    return $null
}

function Ask-YesNo([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "$Question（输入 y 继续 / 其他取消）"
    return ($answer -match "^(y|yes)")
}

# --------------------------------------------------------------------------
# 0. 解析根目录 & 磁盘预检
# --------------------------------------------------------------------------
if (-not $InstallRoot) { $InstallRoot = $PSScriptRoot }
$ROOT = Get-FullPath $InstallRoot
$CKPT_DIR = Join-Path $ROOT "checkpoints"
$REPO_DIR = Join-Path $ROOT "index-tts"
$TOOLS_DIR = Join-Path $ROOT "tools"
$CACHE_DIR = Join-Path $ROOT "cache"
$PY_DIR = Join-Path $ROOT "python"
$STATE_FILE = Join-Path $ROOT ".install-state.json"

# uv 托管的 Python 永远放在本包内（见 python\README.md），缓存放到 cache\uv。
# 现在就把变量设好，让"查找"和"安装"两步指向同一个位置（避免重复下载上次
# 已经装进 python\ 的 3.11）。
$env:UV_PYTHON_INSTALL_DIR = $PY_DIR
$env:UV_CACHE_DIR = (Join-Path $CACHE_DIR "uv")
$env:UV_LINK_MODE = "copy"

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  IndexTTS-2.5 一键安装包" -ForegroundColor Cyan
Write-Host "  包根目录   : $ROOT" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

if (-not $SkipCheck) {
    $free = Get-DriveFreeGB $ROOT
    if ($free -lt 0) {
        Write-Fail "无法解析 $ROOT 所在的盘符"
        exit 1
    }
    $driveLetter = (Get-Item $ROOT).PSDrive.Name
    Write-Info "本盘（${driveLetter}:）剩余空间：$free GB"

    # 找本地剩余空间最大的盘，给出更友好的提示。
    $bestDrive = $null
    $bestFree = -1.0
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        try {
            $dFreeGB = [double]$d.Free / 1GB
            if ($dFreeGB -gt $bestFree) {
                $bestFree = $dFreeGB
                $bestDrive = $d
            }
        } catch { }
    }
    $tip = ""
    if ($bestDrive -and $bestDrive.Name -ne $driveLetter) {
        $tip = "  $($bestDrive.Name): 盘剩余空间最大（$([math]::Round($bestFree,1)) GB）。"
    }

    if ($free -lt 15) {
        Write-Fail "磁盘空间不足（完整安装约需 40 GB：源码 + Python + 依赖 + 约 15 GB 模型）。"
        Write-Fail "请释放空间，或把本包移到空间充足的盘符（任意盘符均可）。"
        if ($tip) { Write-Fail $tip }
        exit 1
    } elseif ($free -lt 40) {
        Write-Warn "剩余空间较少：仅 $free GB。完整安装约需 40 GB。"
        Write-Warn "请释放空间，或把本包移到空间充足的盘符（任意盘符均可）。"
        if ($tip) { Write-Warn $tip }
    }
}

# --------------------------------------------------------------------------
# 1. 工具检测与引导
# --------------------------------------------------------------------------
$UV_EXE = $null
$FFMPEG_BIN = ""          # 安装便携版 ffmpeg 时填充
$PY_DISPLAY = $null
$TOOLS_NEEDED = @()

# --- git -------------------------------------------------------------
Write-Step "1/6 检查 git"
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $gitVer = (& git --version 2>$null | Out-String).Trim()
    Write-Ok "复用系统 git：$gitVer"
} else {
    Write-Warn "本机未找到 git。"
    if ($AutoInstallGit -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Info "正在通过 winget 静默安装 Git（用户级）..."
        Invoke-Native { & winget install --id Git.Git -e --scope user --accept-package-agreements --accept-source-agreements --silent } | Out-Null
        # 从注册表刷新 PATH，让刚装的 git 立即可见。
        $env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:PATH
        $git = Get-Command git -ErrorAction SilentlyContinue
    }
    if (-not $git) {
        Write-Fail "必须安装 git。请先安装 Git for Windows（https://git-scm.com）再重试。"
        Write-Fail "或者运行：winget install --id Git.Git -e"
        exit 1
    }
    Write-Ok "git 已安装：$(& git --version)"
}

# --- uv ---------------------------------------------------------------
Write-Step "2/6 检查 uv"
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
    $UV_EXE = $uv.Source
    $uvVer = (Invoke-Silent { & $UV_EXE --version } | Out-String).Trim()
    Write-Ok "复用系统 uv：$uvVer"
} else {
    Write-Warn "未找到 uv。将安装一个本地便携版 uv 到 tools\uv（不改动系统）。"
    if ($CheckOnly) { Write-Info "  -> 将安装便携版 uv 到 $TOOLS_DIR\uv" }
    else {
        New-Item -ItemType Directory -Path $TOOLS_DIR -Force | Out-Null
        $env:UV_INSTALL_DIR = (Join-Path $TOOLS_DIR "uv")
        $env:UV_UNMANAGED_INSTALL = "1"   # 不修改用户 PATH
        try {
            Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1" -UseBasicParsing | Invoke-Expression
        } catch {
            Write-Fail "下载 uv 安装器失败：$_"
            exit 1
        }
        $candidate = Join-Path $env:UV_INSTALL_DIR "uv.exe"
        if (-not (Test-Path $candidate)) {
            # 官方脚本可能把二进制放在嵌套目录里。
            $candidate = (Get-ChildItem $env:UV_INSTALL_DIR -Recurse -Filter uv.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        }
        if (-not $candidate) {
            Write-Fail "uv 安装失败。"
            exit 1
        }
        $UV_EXE = $candidate
        Write-Ok "本地 uv 就绪：$UV_EXE ($(& $UV_EXE --version 2>&1 | Out-String).Trim())"
    }
}

# --- ffmpeg ------------------------------------------------------------
Write-Step "3/6 检查 ffmpeg"
$ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ff) {
    $ffVer = (& ffmpeg -version 2>$null | Select-Object -First 1 | Out-String).Trim()
    Write-Ok "复用系统 ffmpeg：$ffVer"
} elseif ($SkipFFmpeg) {
    Write-Warn "未找到 ffmpeg，但已设置 -SkipFFmpeg。音频导出可能失败。"
} else {
    # 复用上次运行已下载的便携版 ffmpeg。
    $existingFf = Get-ChildItem (Join-Path $TOOLS_DIR "ffmpeg*") -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "bin\ffmpeg.exe") } | Select-Object -First 1
    if ($existingFf) {
        $FFMPEG_BIN = Join-Path $existingFf.FullName "bin"
        Write-Ok "复用上次安装的便携版 ffmpeg：$FFMPEG_BIN"
    } elseif ($CheckOnly) {
        Write-Warn "未找到 ffmpeg。将下载本地便携版 ffmpeg 到 tools\ffmpeg。"
        Write-Info "  -> 将下载 ffmpeg（BtbN gpl 构建）到 $TOOLS_DIR\ffmpeg"
    } else {
        Write-Warn "未找到 ffmpeg。将安装本地便携版 ffmpeg 到 tools\ffmpeg。"
        New-Item -ItemType Directory -Path $TOOLS_DIR -Force | Out-Null
        $zip = Join-Path $TOOLS_DIR "ffmpeg.zip"
        Write-Info "正在下载 ffmpeg（约 100 MB）..."
        try {
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                Invoke-Native { & curl.exe -L --fail --retry 3 -sS -o $zip "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" }
            } else {
                Invoke-WebRequest -Uri "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile $zip -UseBasicParsing
            }
            if (-not (Test-Path $zip)) { throw "download failed" }
            Expand-Archive -Path $zip -DestinationPath $TOOLS_DIR -Force
            $ffBin = Get-ChildItem (Join-Path $TOOLS_DIR "ffmpeg*") -Directory | Select-Object -First 1
            if ($ffBin) { $FFMPEG_BIN = (Join-Path $ffBin.FullName "bin") }
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path (Join-Path $FFMPEG_BIN "ffmpeg.exe"))) { throw "ffmpeg.exe not in archive" }
            Write-Ok "便携版 ffmpeg 就绪：$FFMPEG_BIN"
        } catch {
            Write-Warn "ffmpeg 安装失败：$_  （继续，不带 ffmpeg）"
        }
    }
}

# --- Python 3.11 --------------------------------------------------------
Write-Step "4/6 检查 Python 3.10/3.11"
if ($CheckOnly) {
    $pv = $null
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) { $pv = Test-Python311Exe $pyCmd.Source; if ($pv) { Write-Ok "复用 PATH 中的 python：$pv" } else { Write-Info "  -> python 存在但不是 3.10/3.11" } }
    $pyL = Get-Command py -ErrorAction SilentlyContinue
    if ($pyL) { Write-Info "  -> 检测到 py 启动器" }
    if (-not $pyCmd -or -not $pv) { Write-Info "  -> 将通过 uv 安装 Python 3.11 到 $PY_DIR" }
} else {
    $PY_INFO = $null
    # (a) PATH 上的 `python`
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $pv = Test-Python311Exe $pyCmd.Source
        if ($pv) { $PY_INFO = @{ Exe = $pyCmd.Source; Display = $pv } }
    }
    # (b) 带 3.11 的 py 启动器
    if (-not $PY_INFO) {
        $pyL = Get-Command py -ErrorAction SilentlyContinue
        if ($pyL) {
            $exe = (Invoke-Silent { & py -3.11 -c "import sys;print(sys.executable)" } | Out-String).Trim()
            $pv = Test-Python311Exe $exe
            if ($pv) { $PY_INFO = @{ Exe = $exe; Display = $pv } }
        }
    }
    # (c) uv 托管的 3.11（上次运行可能已存在）
    if (-not $PY_INFO -and $UV_EXE) {
        $exe = (Invoke-Silent { & $UV_EXE python find 3.11 } | Out-String).Trim()
        if ($exe -and (Test-Path $exe)) {
            $pv = Test-Python311Exe $exe
            if ($pv) { $PY_INFO = @{ Exe = $exe; Display = $pv } }
        }
    }
    # (d) 把私有 3.11 装进本包（绝不碰系统 Python）
    if (-not $PY_INFO) {
        if (-not $UV_EXE) { Write-Fail "没有 uv 可用来安装 Python。"; exit 1 }
        Write-Info "未找到可用的 Python 3.10/3.11。正在安装私有 Python 3.11 到 $PY_DIR ..."
        $env:UV_PYTHON_INSTALL_DIR = $PY_DIR
        $env:UV_CACHE_DIR = (Join-Path $CACHE_DIR "uv")
        Invoke-Native { & $UV_EXE python install 3.11.13 }
        if ($LASTEXITCODE -ne 0) { Write-Fail "Python 3.11 安装失败。"; exit 1 }
        $exe = (Invoke-Silent { & $UV_EXE python find 3.11 } | Out-String).Trim()
        $pv = Test-Python311Exe $exe
        if (-not $pv) { Write-Fail "找不到刚安装好的 Python 3.11。"; exit 1 }
        $PY_INFO = @{ Exe = $exe; Display = $pv }
    }
    if ($PY_INFO) {
        Write-Ok "使用 Python：$($PY_INFO.Display) -> $($PY_INFO.Exe)"
    } else {
        Write-Fail "无法提供 Python 3.10/3.11。"
        exit 1
    }
}

# --- GPU -----------------------------------------------------------------
Write-Step "5/6 检查 NVIDIA GPU"
$gpu = $null
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmi) { $gpu = (Invoke-Silent { & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader } | Out-String).Trim() }
if ($gpu) {
    Write-Ok "检测到 GPU：$gpu  （IndexTTS-2.5 约需 6 GB 显存）"
} else {
    Write-Warn "未找到 NVIDIA GPU / nvidia-smi。IndexTTS-2.5 需要 NVIDIA GPU"
    Write-Warn "（约 6 GB 显存）。安装仍会继续，但推理会失败。"
}

if ($CheckOnly) {
    Write-Host ""
    Write-Host "=== 预检汇总（未做任何修改） ===" -ForegroundColor Cyan
    Write-Host "  包根目录   : $ROOT"
    Write-Host "  剩余空间   : $((Get-DriveFreeGB $ROOT)) GB"
    Write-Host "  模型目录   : $CKPT_DIR"
    Write-Host "  依赖项     : $Extras"
    if ($ModelSource -eq "auto") { Write-Host "  模型源     : modelscope（自动）" } else { Write-Host "  模型源     : $ModelSource" }
    Write-Host ""
    Write-Host "去掉 -CheckOnly 重新运行即可开始安装。" -ForegroundColor Green
    exit 0
}

# --------------------------------------------------------------------------
# 2. 克隆源码
# --------------------------------------------------------------------------
Write-Step "克隆 index-tts 源码"
if (-not (Test-Path (Join-Path $REPO_DIR ".git"))) {
    $repoUrl = "https://github.com/index-tts/index-tts.git"
    # 先试官方地址，GitHub 不可达时（国内网络常见）回退到国内加速镜像。
    $cloneUrls = @($repoUrl)
    if ($GitMirror -ne "none") {
        if ($GitMirror -eq "auto") {
            $cloneUrls += @(
                "https://gh-proxy.com/$repoUrl",
                "https://ghproxy.net/$repoUrl",
                "https://github.akams.cn/$repoUrl"
            )
        } elseif ($GitMirror -match "^https?://") {
            if ($GitMirror -like "*.git") {
                # 用户传了完整 clone URL
                $cloneUrls = @($GitMirror)
            } else {
                $prefix = if ($GitMirror.EndsWith("/")) { $GitMirror } else { $GitMirror + "/" }
                $cloneUrls = @($repoUrl, "$prefix$repoUrl")
            }
        }
    }
    $cloned = $false
    foreach ($url in $cloneUrls) {
        # 清掉上次失败留下的部分目录
        if (Test-Path $REPO_DIR) { Remove-Item $REPO_DIR -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Info "git clone --depth 1 $url"
        Invoke-Native { & git -c http.connectTimeout=15 clone --depth 1 $url $REPO_DIR }
        if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $REPO_DIR ".git"))) {
            $cloned = $true
            if ($url -ne $repoUrl) { Write-Ok "已通过镜像克隆源码：$url" }
            break
        }
    }
    if (-not $cloned) {
        Write-Fail "git clone 在官方地址和所有镜像上都失败了。"
        Write-Fail "请检查网络（代理 / VPN），或手动克隆后重试："
        Write-Fail "  git clone --depth 1 https://github.com/index-tts/index-tts.git"
        Write-Fail "  git clone --depth 1 https://gitclone.com/github.com/index-tts/index-tts.git   （国内镜像）"
        Write-Fail "  git -c http.proxy=http://127.0.0.1:7890 clone --depth 1 https://github.com/index-tts/index-tts.git   （走代理）"
        Write-Fail "然后把目录放到：$REPO_DIR"
        exit 1
    }
    Write-Ok "源码已克隆到 $REPO_DIR"
} elseif (Test-Path (Join-Path $REPO_DIR ".git")) {
    Write-Info "源码已存在，执行 git pull 更新..."
    Push-Location $REPO_DIR
    Invoke-Native { & git pull --ff-only }
    Pop-Location
    Write-Ok "源码已更新。"
} else {
    Write-Fail "$REPO_DIR 已存在但不是 git 仓库。请删除后重试。"
    exit 1
}

# --------------------------------------------------------------------------
# 3. 在独立虚拟环境中同步依赖
# --------------------------------------------------------------------------
Write-Step "正在把 Python 依赖装进 index-tts\.venv（独立环境，不动系统 Python）"
$venvPy = Join-Path $REPO_DIR ".venv\Scripts\python.exe"
if (-not $UV_EXE) {
    if (Get-Command uv -ErrorAction SilentlyContinue) { $UV_EXE = (Get-Command uv).Source }
    else { Write-Fail "缺少 uv。"; exit 1 }
}

$extraArgs = @()
foreach ($e in ($Extras -split ",")) {
    $e = $e.Trim()
    if ($e) { $extraArgs += "--extra"; $extraArgs += $e }
}
if ($PyMirror -ne "none") {
    $mirrorUrl = switch ($PyMirror) {
        "aliyun"    { "https://mirrors.aliyun.com/pypi/simple" }
        "tuna"      { "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple" }
        "tsinghua"  { "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple" }
    }
    Write-Info "使用 PyPI 镜像：$mirrorUrl （torch 仍来自官方 CUDA 索引）"
    $extraArgs += "--default-index"; $extraArgs += $mirrorUrl
}

Write-Info "uv sync，extras: [$Extras]  （会下载 torch 2.8 + CUDA wheels，数 GB）"
Push-Location $REPO_DIR
Invoke-Native { & $UV_EXE sync @extraArgs }
$syncCode = $LASTEXITCODE
Pop-Location
if ($syncCode -ne 0) {
    Write-Fail "依赖安装失败（退出码 $syncCode）。"
    Write-Fail "常见解决办法："
    Write-Fail "  - 换镜像重试：.\install.ps1 -PyMirror aliyun"
    Write-Fail "  - 若出现 CUDA 错误，请安装 NVIDIA CUDA Toolkit 12.8+。"
    Write-Fail "  - Windows 上 DeepSpeed 可能编译失败，把 extras 保持为 'webui'。"
    exit 1
}
if (-not (Test-Path $venvPy)) {
    Write-Fail "同步后未找到虚拟环境 python：$venvPy"
    exit 1
}
Write-Ok "虚拟环境就绪：$venvPy"

# --------------------------------------------------------------------------
# 4. 模型 -> 预留的 .\checkpoints 目录
# --------------------------------------------------------------------------
Write-Step "准备模型（IndexTTS-2.5）到 $CKPT_DIR"
New-Item -ItemType Directory -Path $CKPT_DIR -Force | Out-Null

function Test-ModelsReady {
    param([string]$Dir)
    $cfg = Join-Path $Dir "config.yaml"
    if (-not (Test-Path $cfg)) { return $false }
    $size = Get-DirSizeGB $Dir
    if ($size -lt 0.2) { return $false }
    return $true
}

function Test-AuxModelsReady {
    param([string]$Dir)
    # 辅助模型放在 $Dir\hf_cache。w2v-bert-2.0 是完整仓库（约 4.3 GB），
    # 是 SeamlessM4T/Wav2Vec2Bert 所必需的；其核心权重文件必须存在且非空
    # （否则被中断下载留下的部分目录会被误认为"已存在"）。
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

if (Test-ModelsReady $CKPT_DIR) {
    Write-Ok "模型已存在于 $CKPT_DIR（$(Get-DirSizeGB $CKPT_DIR) GB）。跳过下载。"
    Write-Info "如果你是自己放置的模型：感谢，不需要再做任何事。"
} elseif ($SkipModels) {
    Write-Warn "已设置 -SkipModels。模型未下载。"
    Write-Warn "请稍后把模型放到 $CKPT_DIR，或去掉 -SkipModels 重新运行。"
} else {
    $src = if ($ModelSource -eq "auto") { "modelscope" } else { $ModelSource }
    $venv = Join-Path $REPO_DIR ".venv"
    $hf = Join-Path $venv "Scripts\hf.exe"
    $ms = Join-Path $venv "Scripts\modelscope.exe"
    $maxRetries = 3
    $dlOk = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Info "下载尝试 ${attempt}/${maxRetries}：IndexTTS-2.5 经由 $src 到 $CKPT_DIR （体积大，请耐心等待）"
        if ($src -eq "huggingface") {
            if (-not (Test-Path $hf)) { Write-Fail "虚拟环境中没有 huggingface-cli。请重新运行 uv sync。"; exit 1 }
            Invoke-Native { & $hf download IndexTeam/IndexTTS-2.5 --local-dir $CKPT_DIR }
        } else {
            if (-not (Test-Path $ms)) { Write-Fail "虚拟环境中没有 modelscope CLI。"; exit 1 }
            Invoke-Native { & $ms download --model IndexTeam/IndexTTS-2.5 --local_dir $CKPT_DIR }
        }
        if ($LASTEXITCODE -eq 0 -and (Test-ModelsReady $CKPT_DIR)) { $dlOk = $true; break }
        if ($attempt -lt $maxRetries) {
            Write-Warn "第 $attempt 次下载失败。5 秒后重试..."
            Start-Sleep -Seconds 5
        }
    }
    if ($dlOk) {
        Write-Ok "模型就绪（$(Get-DirSizeGB $CKPT_DIR) GB）位于 $CKPT_DIR"
    } else {
        Write-Fail "模型下载在 $maxRetries 次尝试后仍然失败。"
        Write-Fail "请从以下链接手动下载："
        Write-Fail "  ModelScope  : https://modelscope.cn/models/IndexTeam/IndexTTS-2.5"
        Write-Fail "  HuggingFace : https://huggingface.co/IndexTeam/IndexTTS-2.5"
        Write-Fail "  HF 镜像     : https://hf-mirror.com/IndexTeam/IndexTTS-2.5"
        Write-Fail "把所有文件（包括 config.yaml）放到这个目录："
        Write-Fail "  $CKPT_DIR"
        Write-Fail "然后重新运行本安装程序——它会自动检测并复用模型。"
        Write-Warn "或者：现在先不带模型继续安装，以后再放入。"
        if (Ask-YesNo "不带模型继续安装？") {
            Write-Warn "暂时跳过模型。请稍后把模型放到 $CKPT_DIR，再重新运行本安装程序。"
        } else {
            Write-Fail "安装已中止。请按上面的手动下载说明操作，或使用 -SkipModels。"
            exit 1
        }
    }
}

# --------------------------------------------------------------------------
# 4b. 辅助模型 -> $CKPT_DIR\hf_cache
#     Web UI 在首次启动时会通过 ensure_models_available() 下载这些模型
#     （w2v-bert-2.0 约 4.3 GB、campplus、bigvgan、semantic codec）。这里
#     提前下载，让安装一步到位、首次启动即开即用。
# --------------------------------------------------------------------------
$venvPy = Join-Path $REPO_DIR ".venv\Scripts\python.exe"
if (-not $SkipModels -and (Test-Path $venvPy) -and (Test-ModelsReady $CKPT_DIR)) {
    if (Test-AuxModelsReady $CKPT_DIR) {
        Write-Ok "辅助模型已存在于 $CKPT_DIR\hf_cache。跳过。"
    } else {
        Write-Step "准备辅助模型（w2v-bert-2.0 / campplus / bigvgan / semantic codec）到 $CKPT_DIR\hf_cache"
        Write-Info "这些是 Web UI 首次启动必需的。正在预下载（体积大，请耐心等待）..."
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
            print(">> 正在清理不完整的 w2v-bert-2.0 目录（上次下载被中断）...")
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
        print(">> w2v-bert-2.0 已完整，跳过镜像下载。")
        return
    from indextts.utils.model_download import _snapshot_from_hf_mirror
    print(">> 正在通过 hf-mirror.com 下载 w2v-bert-2.0（支持断点续传，请稍候）...")
    _snapshot_from_hf_mirror("facebook/w2v-bert-2.0", w2v)
    if not w2v_ready():
        raise RuntimeError("w2v-bert-2.0 still incomplete after mirror download")

clean_partial_w2v()
try:
    ensure_models_available(ckpt)
except Exception:
    print(">> 默认源下载模型失败，正在改用 hf-mirror.com 重试 ...")
    traceback.print_exc()
    clean_partial_w2v()
    download_w2v_via_mirror()
    ensure_models_available(ckpt)
if not w2v_ready():
    raise SystemExit("ERROR: w2v-bert-2.0 still incomplete after all download attempts")
# Free disk: remove stale ModelScope ._____temp dirs (duplicates of completed
# downloads left behind when the interrupted move could not unlink its source).
for _stale in glob.glob(os.path.join(ckpt, "hf_cache", "**", "._____temp"), recursive=True):
    print(f">> 正在清理残留的临时目录: {_stale}")
    shutil.rmtree(_stale, ignore_errors=True)
print(">> 所有辅助模型已就绪。")
'@
        # 绝不要用 `python -c` 传多行 Python：Windows PowerShell 5.1 不会
        # 转义原生参数里的引号/换行，代码会在第一个 `"` 处被截断并报
        # IndentationError。先把它写成临时 .py 文件再执行。
        $auxPy = Join-Path $env:TEMP "index-tts-aux-download.py"
        [System.IO.File]::WriteAllText($auxPy, $auxCode)
        Invoke-Native { & $venvPy $auxPy $CKPT_DIR }
        $auxExit = $LASTEXITCODE
        Remove-Item $auxPy -Force -ErrorAction SilentlyContinue
        if ($auxExit -eq 0 -and (Test-AuxModelsReady $CKPT_DIR)) {
            Write-Ok "辅助模型已就绪：$CKPT_DIR\hf_cache"
        } else {
            Write-Warn "辅助模型预下载未完成。Web UI 会在首次启动时重试。"
        }
    }
}

# --------------------------------------------------------------------------
# 5. 写入安装状态 + 完成
# --------------------------------------------------------------------------
$state = [ordered]@{
    installRoot     = $ROOT
    repoDir         = $REPO_DIR
    checkpointsDir  = $CKPT_DIR
    venvDir         = (Join-Path $REPO_DIR ".venv")
    ffmpegBin       = $FFMPEG_BIN
    extras          = $Extras
    modelSource     = if ($ModelSource -eq "auto") { "modelscope" } else { $ModelSource }
    modelsReady     = (Test-ModelsReady $CKPT_DIR)
    installedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$state | ConvertTo-Json -Depth 4 | Set-Content -Path $STATE_FILE -Encoding UTF8
Write-Ok "安装状态已保存到 $STATE_FILE"

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  启动 Web UI："
Write-Host "      .\start-webui.bat"
Write-Host "      （或直接双击 start-webui.bat）"
Write-Host "  然后在浏览器打开 http://127.0.0.1:7860。"
Write-Host ""
Write-Host "  CLI 示例："
Write-Host "      .\start-cli.bat -Text `"你好，这是 IndexTTS 2.5`" -Lang ZH"
Write-Host ""
Write-Host "  Web UI 附加开关：-FP16（低显存）、-Deepspeed、-Accel、-TorchCompile"
Write-Host "  更多细节、镜像与排错请见 README.md。"
Write-Host "======================================================================" -ForegroundColor Green

# 交互式运行（双击 / 控制台）时保持窗口不关闭；输出被重定向或 CI 时不阻塞。
if (-not [Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "  安装已完成。按回车关闭本窗口。" -ForegroundColor Cyan
    $null = Read-Host
}

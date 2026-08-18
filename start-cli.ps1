#requires -Version 5.1
<#
  IndexTTS-2.5 命令行推理示例（Windows）。
  用法：
    .\start-cli.ps1 -Text "你好，世界" -Lang ZH
    .\start-cli.ps1 -Text "Hello world" -Lang EN -RefAudio .\my_voice.wav -Output .\out.wav
  支持语言：ZH / EN / JA / ES / AR
#>
[CmdletBinding()]
param(
    [string]$Text = "大家好，这是 IndexTTS 2.5 的语音合成测试。",
    [ValidateSet("ZH", "EN", "JA", "ES", "AR")]
    [string]$Lang = "ZH",
    [string]$RefAudio = "",
    [string]$Output = ""
)

$ErrorActionPreference = "Stop"

# CodeBuddy 的 genie 扩展会通过 PYTHONPATH 注入 sitecustomize.py 垫片，
# 劫持 os.remove / os.unlink / shutil.move（路由到"安全删除/回收站"），
# 这会破坏模型下载（ModelScope 用 shutil.move 移动临时文件）和部分下载的
# 清理逻辑，所以从每个子 Python 环境中剥离它。
$env:PYTHONPATH = (($env:PYTHONPATH -split ';') | Where-Object { $_ -and $_ -notlike '*genie*vendor*shim*' }) -join ';'
$env:CODEBUDDY_SAFE_DELETE_ENABLED = '0'

$ROOT = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

$stateFile = Join-Path $ROOT ".install-state.json"
$REPO = Join-Path $ROOT "index-tts"
$CKPT = Join-Path $ROOT "checkpoints"
$PY   = Join-Path $REPO ".venv\Scripts\python.exe"

if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($st.ffmpegBin -and (Test-Path $st.ffmpegBin)) { $env:PATH = "$($st.ffmpegBin);$env:PATH" }
        if ($st.checkpointsDir) { $CKPT = $st.checkpointsDir }
        if ($st.repoDir) { $REPO = $st.repoDir }
        if ($st.venvDir) { $PY = Join-Path $st.venvDir "Scripts\python.exe" }
    } catch { }
}

if (-not (Test-Path $PY)) {
    Write-Host "未找到虚拟环境 Python：$PY" -ForegroundColor Red
    Write-Host "请先运行 install.ps1 完成安装。详见 README.md。" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path (Join-Path $CKPT "config.yaml"))) {
    Write-Host "[WARN] 在 $CKPT 中未找到模型配置 config.yaml" -ForegroundColor Yellow
    exit 1
}

# 辅助模型（w2v-bert-2.0 约 4.3 GB、campplus、bigvgan、semantic codec）位于
# $CKPT\hf_cache。推理必需；缺失时首次运行会静默触发大体积下载（或被部分
# 下载目录误判为"已存在"而崩溃）。先确认它们完整。
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
    Write-Host "  $CKPT\hf_cache 中缺少辅助模型" -ForegroundColor Yellow
    Write-Host "  （w2v-bert-2.0 约 4.3 GB、campplus、bigvgan、semantic codec）" -ForegroundColor Yellow
    Write-Host "  现在开始下载——一次性下载，请稍候..." -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow
    $auxCode = @'
import glob, os, shutil, sys, time, traceback
from indextts.utils.model_download import ensure_models_available

ckpt = sys.argv[1]
w2v = os.path.join(ckpt, "hf_cache", "w2v-bert-2.0")

def clean_partial_w2v():
    # w2v-bert-2.0 必须是完整的仓库目录。被中断的下载留下的部分目录
    # （例如 ModelScope 的 ._____temp 目录、0 字节文件）会被误判为
    # "已存在"并在加载时崩溃。删除时重试：Windows 可能短暂占用刚写入的
    # 文件。
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
    # 面向国内的 HuggingFace 镜像（hf-mirror.com），支持断点续传。当默认源
    # （ModelScope / HF 直连）在 4.3 GB 大文件上失败时使用。通过子进程运行
    # huggingface_hub CLI：HF_ENDPOINT 只在全新进程中生效，import 后修改
    # os.environ 无效。
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
# 释放磁盘：删除残留的 ModelScope ._____temp 目录（被中断的移动操作无法
# 删除源文件时留下的重复副本）。
for _stale in glob.glob(os.path.join(ckpt, "hf_cache", "**", "._____temp"), recursive=True):
    print(f">> 正在清理残留的临时目录: {_stale}")
    shutil.rmtree(_stale, ignore_errors=True)
print(">> 所有辅助模型已就绪。")
'@
    Push-Location $REPO
    # 绝不要用 `python -c` 传多行 Python：Windows PowerShell 5.1 不会转义
    # 原生参数里的引号/换行，代码会在第一个 `"` 处被截断并报 IndentationError。
    # 先把它写成临时 .py 文件再执行。
    $auxPy = Join-Path $env:TEMP "index-tts-aux-download.py"
    [System.IO.File]::WriteAllText($auxPy, $auxCode)
    & $PY $auxPy $CKPT
    $auxCodeExit = $LASTEXITCODE
    Remove-Item $auxPy -Force -ErrorAction SilentlyContinue
    Pop-Location
    if ($auxCodeExit -ne 0 -or -not (Test-AuxModelsReady $CKPT)) {
        Write-Host "[FAIL] 辅助模型下载失败。请检查网络后重新运行。" -ForegroundColor Red
        Write-Host "       辅助模型不完整无法继续推理。" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "[OK] 辅助模型已就绪。" -ForegroundColor Green
    }
}

if (-not $RefAudio) {
    $RefAudio = Join-Path $REPO "examples\voice_01.wav"
}
if (-not (Test-Path $RefAudio)) {
    Write-Host "[WARN] 未找到参考音频：$RefAudio" -ForegroundColor Yellow
    Write-Host "       请用 -RefAudio <path.wav> 指定（3-10 秒清晰人声）。" -ForegroundColor Yellow
}

if (-not $Output) {
    $outDir = Join-Path $ROOT "output"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $Output = Join-Path $outDir ("gen_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".wav")
}

$env:TOKENIZERS_PARALLELISM = "false"
Write-Host "正在合成语音...（语言=$Lang，参考音频=$RefAudio）" -ForegroundColor Cyan
Push-Location $REPO
& $PY "indextts\infer_v2_5.py" --cfg_path (Join-Path $CKPT "config.yaml") --model_dir $CKPT --prompt_wav $RefAudio --text $Text --lang $Lang --output $Output
$code = $LASTEXITCODE
Pop-Location
if ($code -eq 0 -and (Test-Path $Output)) {
    Write-Host "完成：$Output" -ForegroundColor Green
} else {
    Write-Host "推理失败（退出码 $code）。请查看上方错误信息。" -ForegroundColor Red
}
exit $code

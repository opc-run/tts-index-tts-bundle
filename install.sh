#!/usr/bin/env bash
# =============================================================================
#  IndexTTS-2.5 一键安装程序（Linux / macOS）
#  https://github.com/index-tts/index-tts
#
#  原则（与 Windows 安装器一致）：
#    1. 检测并复用已有的工具（git / uv / ffmpeg / Python 3.10/3.11）。
#    2. 只安装缺失的部分，并装到本包的本地目录（tools/、cache/）。
#    3. 所有 Python 依赖都在 index-tts/.venv（系统 Python 不受影响）。
#    4. 模型下载到预留的 ./checkpoints 目录——或者复用你已手动放置好的模型。
#
#  用法：
#    chmod +x install.sh && ./install.sh
#    ./install.sh --model-source huggingface
#    ./install.sh --py-mirror aliyun
# =============================================================================
set -euo pipefail

# ---- 解析参数 ----------------------------------------------------------------
MODEL_SOURCE="${MODEL_SOURCE:-auto}"      # auto|huggingface|modelscope
PY_MIRROR="${PY_MIRROR:-none}"            # none|aliyun|tuna|tsinghua
GIT_MIRROR="${GIT_MIRROR:-auto}"          # auto|none|镜像前缀地址|完整克隆地址
EXTRAS="${EXTRAS:-webui}"
SKIP_MODELS="${SKIP_MODELS:-0}"
CHECK_ONLY="${CHECK_ONLY:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-source) MODEL_SOURCE="$2"; shift 2 ;;
    --py-mirror)    PY_MIRROR="$2";    shift 2 ;;
    --git-mirror)   GIT_MIRROR="$2";   shift 2 ;;
    --extras)       EXTRAS="$2";       shift 2 ;;
    --skip-models)  SKIP_MODELS=1;     shift ;;
    --check-only)   CHECK_ONLY=1;      shift ;;
    *) echo "未知选项：$1"; exit 1 ;;
  esac
done

# ---- 根目录 & 颜色 --------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKPT_DIR="$ROOT/checkpoints"
REPO_DIR="$ROOT/index-tts"
TOOLS_DIR="$ROOT/tools"
CACHE_DIR="$ROOT/cache"
PY_DIR="$ROOT/python"
STATE_FILE="$ROOT/.install-state.json"

if [[ -t 1 ]]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi
step() { printf "\n${C_CYAN}==> %s${C_OFF}\n" "$*"; }
ok()   { printf "  ${C_GREEN}[OK]${C_OFF} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}[WARN]${C_OFF} %s\n" "$*"; }
fail() { printf "  ${C_RED}[FAIL]${C_OFF} %s\n" "$*"; }

# ---- 辅助函数 ----------------------------------------------------------------
free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
dir_size_gb() { du -sk "$1" 2>/dev/null | awk '{printf "%.2f", $1/1048576}'; }
ask_yes_no() {
  if [[ ! -t 0 ]]; then return 1; fi
  local ans
  printf "  %s（输入 y 继续 / 其他取消） " "$*"
  read -r ans || return 1
  [[ "$ans" =~ ^(y|yes)$ ]]
}

is_python_ok() {
  local exe="$1" out ver
  [[ -n "$exe" && -x "$exe" ]] || return 1
  out=$("$exe" --version 2>&1) || return 1
  ver=$(echo "$out" | sed -n 's/^Python[[:space:]]*\([0-9]*\)\.\([0-9]*\).*/\1.\2/p')
  [[ "$ver" == "3.10" || "$ver" == "3.11" ]]
}

# ---- 0. banner + 磁盘 ----------------------------------------------------------
echo ""
echo "======================================================================"
echo "  IndexTTS-2.5 一键安装包（Linux/macOS）"
echo "  包根目录 : $ROOT"
echo "======================================================================"

FREE_KB=$(free_kb "$ROOT")
if [[ -z "$FREE_KB" ]]; then
  fail "无法确定 $ROOT 的剩余空间"; exit 1
fi
FREE_GB=$((FREE_KB / 1048576))
echo "  剩余空间 : ${FREE_GB} GB"
if [[ $FREE_GB -lt 15 ]]; then
  fail "磁盘空间不足（完整安装约需 40 GB）。请释放空间或移动本包。"
  exit 1
elif [[ $FREE_GB -lt 40 ]]; then
  warn "剩余空间较少（${FREE_GB} GB）。完整安装约需 40 GB。"
  warn "提示：释放空间，或把本包移到空间充足的挂载点（任意分区均可）："
  df -h 2>/dev/null | awk '{print "    " $0}' | head -n 10
fi

# ---- 1. git ----------------------------------------------------------------
step "1/6 检查 git"
if command -v git >/dev/null 2>&1; then
  ok "复用系统 git：$(git --version)"
else
  fail "必须安装 git。请先安装，例如："
  fail "  Debian/Ubuntu: sudo apt-get install -y git"
  fail "  macOS:         brew install git  （或 xcode-select --install）"
  exit 1
fi

# ---- 2. uv -----------------------------------------------------------------
UV_EXE="${UV_EXE:-}"
step "2/6 检查 uv"
if command -v uv >/dev/null 2>&1; then
  UV_EXE="$(command -v uv)"
  ok "复用系统 uv：$(uv --version)"
else
  warn "未找到 uv。将安装一个本地便携版 uv 到 tools/uv（不改动系统）。"
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "  -> 将安装便携版 uv 到 $TOOLS_DIR/uv"
  else
    mkdir -p "$TOOLS_DIR"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
      fail "下载 uv 需要 curl 或 wget。"; exit 1
    fi
    if command -v curl >/dev/null 2>&1; then
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$TOOLS_DIR/uv" UV_UNMANAGED_INSTALL=1 sh
    else
      wget -qO- https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$TOOLS_DIR/uv" UV_UNMANAGED_INSTALL=1 sh
    fi
    UV_EXE="$TOOLS_DIR/uv/uv"
    if [[ ! -x "$UV_EXE" ]]; then
      UV_EXE="$(find "$TOOLS_DIR/uv" -name uv -type f 2>/dev/null | head -n1 || true)"
    fi
    if [[ -z "$UV_EXE" ]]; then
      fail "uv 安装失败。"; exit 1
    fi
    ok "本地 uv 就绪：$UV_EXE ($("$UV_EXE" --version))"
  fi
fi

# ---- 3. ffmpeg --------------------------------------------------------------
step "3/6 检查 ffmpeg"
if command -v ffmpeg >/dev/null 2>&1; then
  ok "复用系统 ffmpeg：$(ffmpeg -version 2>/dev/null | head -n1)"
else
  warn "未找到 ffmpeg。建议安装以获得最佳效果，例如："
  warn "  Debian/Ubuntu: sudo apt-get install -y ffmpeg"
  warn "  macOS:         brew install ffmpeg"
  warn "  （安装会继续；音频导出能力可能受限）"
fi

# ---- 4. Python 3.11 ----------------------------------------------------------
step "4/6 检查 Python 3.10/3.11"
PY_INFO=""
for cand in "${PYTHON:-}" "python3.11" "python3" "python"; do
  if [[ -n "$cand" ]] && command -v "$cand" >/dev/null 2>&1; then
    if is_python_ok "$(command -v "$cand")"; then
      PY_INFO="$(command -v "$cand")"
      break
    fi
  fi
done

if [[ -n "$PY_INFO" ]]; then
  ok "复用 Python：$("$PY_INFO" --version)"
elif [[ "$CHECK_ONLY" == "1" ]]; then
  warn "未找到可用的 Python 3.10/3.11。"
  echo "  -> 将通过 uv 安装 Python 3.11 到 $PY_DIR"
elif [[ -n "$UV_EXE" ]]; then
  warn "未找到可用的 Python 3.10/3.11。正在安装私有 Python 3.11 到 $PY_DIR ..."
  export UV_PYTHON_INSTALL_DIR="$PY_DIR"
  export UV_CACHE_DIR="$CACHE_DIR/uv"
  "$UV_EXE" python install 3.11.13
  PY_INFO="$("$UV_EXE" python find 3.11 2>/dev/null || true)"
  if ! is_python_ok "$PY_INFO"; then
    fail "Python 3.11 安装失败。"; exit 1
  fi
  ok "私有 Python 就绪：$("$PY_INFO" --version)"
else
  fail "未找到可用的 Python 3.10/3.11，且没有 uv。"
  fail "请先安装 Python 3.11 或 uv，然后重新运行。"
  exit 1
fi

# ---- 5. GPU ------------------------------------------------------------------
step "5/6 检查 NVIDIA GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
  ok "GPU：$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n1)"
else
  warn "未找到 NVIDIA GPU / nvidia-smi。IndexTTS-2.5 需要约 6 GB 显存的 NVIDIA GPU。"
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo ""
  echo "=== 预检汇总（未做任何修改） ==="
  echo "  包根目录  : $ROOT"
  echo "  剩余空间  : ${FREE_GB} GB"
  echo "  模型目录  : $CKPT_DIR"
  echo "  依赖项    : $EXTRAS"
  echo "  模型源    : ${MODEL_SOURCE}"
  echo ""
  echo "去掉 --check-only 重新运行即可开始安装。"
  exit 0
fi

# ---- 6. clone -----------------------------------------------------------------
step "克隆 index-tts 源码"
if [[ ! -d "$REPO_DIR/.git" ]]; then
  REPO_URL="https://github.com/index-tts/index-tts.git"
  # 先试官方地址，GitHub 不可达时（国内网络常见）回退到国内加速镜像。
  CLONE_URLS=("$REPO_URL")
  if [[ "$GIT_MIRROR" != "none" ]]; then
    if [[ "$GIT_MIRROR" == "auto" ]]; then
      CLONE_URLS+=(
        "https://gh-proxy.com/$REPO_URL"
        "https://ghproxy.net/$REPO_URL"
        "https://github.akams.cn/$REPO_URL"
      )
    elif [[ "$GIT_MIRROR" == https://* ]]; then
      if [[ "$GIT_MIRROR" == *.git ]]; then
        CLONE_URLS=("$GIT_MIRROR")   # 用户传了完整克隆地址
      else
        P="${GIT_MIRROR%/}"
        CLONE_URLS=("$REPO_URL" "$P/$REPO_URL")
      fi
    fi
  fi
  CLONED=0
  for url in "${CLONE_URLS[@]}"; do
    rm -rf "$REPO_DIR"   # 清掉上次失败留下的部分目录
    echo "    git clone --depth 1 $url"
    if git -c http.connectTimeout=15 clone --depth 1 "$url" "$REPO_DIR" && [[ -d "$REPO_DIR/.git" ]]; then
      CLONED=1
      if [[ "$url" != "$REPO_URL" ]]; then ok "已通过镜像克隆源码：$url"; fi
      break
    fi
  done
  if [[ $CLONED -eq 0 ]]; then
    fail "git clone 在官方地址和所有镜像上都失败了。"
    fail "请检查网络（代理 / VPN），或手动克隆后重试："
    fail "  git clone --depth 1 https://github.com/index-tts/index-tts.git"
    fail "  git clone --depth 1 https://gitclone.com/github.com/index-tts/index-tts.git   （国内镜像）"
    fail "  git -c http.proxy=http://127.0.0.1:7890 clone --depth 1 https://github.com/index-tts/index-tts.git   （走代理）"
    fail "然后把目录放到：$REPO_DIR"
    exit 1
  fi
  ok "源码已克隆到 $REPO_DIR"
elif [[ -d "$REPO_DIR/.git" ]]; then
  (cd "$REPO_DIR" && git pull --ff-only)
  ok "源码已更新。"
else
  fail "$REPO_DIR 已存在但不是 git 仓库。请删除后重试。"; exit 1
fi

# ---- 7. deps -------------------------------------------------------------------
step "正在把 Python 依赖装进 index-tts/.venv（隔离环境）"
if [[ -z "$UV_EXE" ]]; then
  UV_EXE="$(command -v uv)" || { fail "缺少 uv。"; exit 1; }
fi
export UV_CACHE_DIR="$CACHE_DIR/uv"
export UV_PYTHON_INSTALL_DIR="$PY_DIR"

EXTRA_ARGS=()
IFS=',' read -ra EXTRAS_ARR <<< "$EXTRAS"
for e in "${EXTRAS_ARR[@]}"; do
  e="$(echo "$e" | tr -d ' ' || true)"
  if [[ -n "$e" ]]; then EXTRA_ARGS+=(--extra "$e"); fi
done
case "$PY_MIRROR" in
  aliyun)   EXTRA_ARGS+=(--default-index "https://mirrors.aliyun.com/pypi/simple") ;;
  tuna|tsinghua) EXTRA_ARGS+=(--default-index "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple") ;;
esac

echo "  Extras: [$EXTRAS]  （会下载 torch 2.8 + CUDA wheels，数 GB）"
(cd "$REPO_DIR" && "$UV_EXE" sync "${EXTRA_ARGS[@]}")

VENV_PY="$REPO_DIR/.venv/bin/python"
[[ -x "$VENV_PY" ]] || { fail "未找到虚拟环境 Python：$VENV_PY"; exit 1; }
ok "虚拟环境就绪：$VENV_PY"

# ---- 8. models ------------------------------------------------------------------
step "准备模型（IndexTTS-2.5）到 $CKPT_DIR"
mkdir -p "$CKPT_DIR"

models_ready() {
  [[ -f "$CKPT_DIR/config.yaml" ]] || return 1
  local size; size=$(dir_size_gb "$CKPT_DIR")
  awk -v s="$size" 'BEGIN { exit !(s > 0.2) }'
}

if models_ready; then
  ok "模型已存在于 $CKPT_DIR（$(dir_size_gb "$CKPT_DIR") GB）。跳过下载。"
elif [[ "$SKIP_MODELS" == "1" ]]; then
  warn "已设置 --skip-models。模型未下载。请稍后放到 $CKPT_DIR。"
else
  SRC="$MODEL_SOURCE"
  if [[ "$SRC" == "auto" ]]; then SRC="modelscope"; fi
  HF="$REPO_DIR/.venv/bin/hf"
  MS="$REPO_DIR/.venv/bin/modelscope"
  MAX_RETRIES=3
  DL_OK=0
  for attempt in 1 2 3; do
    echo "  下载尝试 ${attempt}/${MAX_RETRIES}：IndexTTS-2.5 经由 $SRC 到 $CKPT_DIR（体积大，请耐心等待）"
    if [[ "$SRC" == "huggingface" ]]; then
      [[ -x "$HF" ]] || { fail "虚拟环境中没有 huggingface-cli。"; exit 1; }
      if "$HF" download IndexTeam/IndexTTS-2.5 --local-dir "$CKPT_DIR" && models_ready; then
        DL_OK=1; break
      fi
    else
      [[ -x "$MS" ]] || { fail "虚拟环境中没有 modelscope CLI。"; exit 1; }
      if "$MS" download --model IndexTeam/IndexTTS-2.5 --local_dir "$CKPT_DIR" && models_ready; then
        DL_OK=1; break
      fi
    fi
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      warn "第 $attempt 次下载失败。5 秒后重试..."
      sleep 5
    fi
  done
  if [[ $DL_OK -eq 1 ]]; then
    ok "模型就绪（$(dir_size_gb "$CKPT_DIR") GB）位于 $CKPT_DIR"
  else
    fail "模型下载在 ${MAX_RETRIES} 次尝试后仍然失败。"
    echo "  请从以下链接手动下载："
    echo "    ModelScope  : https://modelscope.cn/models/IndexTeam/IndexTTS-2.5"
    echo "    HuggingFace : https://huggingface.co/IndexTeam/IndexTTS-2.5"
    echo "    HF 镜像     : https://hf-mirror.com/IndexTeam/IndexTTS-2.5"
    echo "  把所有文件（包括 config.yaml）放到这个目录："
    echo "    $CKPT_DIR"
    echo "  然后重新运行本安装程序——它会自动检测并复用模型。"
    warn "或者：现在先不带模型继续安装，以后再放入。"
    if ask_yes_no "不带模型继续安装？"; then
      warn "暂时跳过模型。请稍后放到 $CKPT_DIR，再重新运行本安装程序。"
    else
      fail "安装已中止。请按上面的手动下载说明操作，或使用 --skip-models。"
      exit 1
    fi
  fi
fi

# ---- 8b. 辅助模型 -> $CKPT_DIR/hf_cache --------------------------
# Web UI 在首次启动时会通过 ensure_models_available() 下载这些模型
# （w2v-bert-2.0 约 4.3 GB、campplus、bigvgan、semantic codec）。这里
# 提前下载，让安装一步到位、首次启动即开即用。
aux_models_ready() {
  local hf="$CKPT_DIR/hf_cache"
  [[ -d "$hf" ]] || return 1
  local w2v="$hf/w2v-bert-2.0/model.safetensors"
  [[ -f "$w2v" ]] || return 1
  local sz; sz=$(stat -c%s "$w2v" 2>/dev/null || stat -f%z "$w2v" 2>/dev/null || echo 0)
  awk -v s="$sz" 'BEGIN { exit !(s > 100 * 1024 * 1024) }' || return 1
  for f in "campplus_cn_common.bin" "semantic_codec_model.safetensors" \
           "bigvgan/config.json" "bigvgan/bigvgan_generator.pt"; do
    [[ -f "$hf/$f" ]] || return 1
  done
  return 0
}

VENV_PY="$REPO_DIR/.venv/bin/python"
if [[ "$SKIP_MODELS" != "1" && -x "$VENV_PY" ]] && models_ready; then
  if aux_models_ready; then
    ok "辅助模型已存在于 $CKPT_DIR/hf_cache。跳过。"
  else
    step "准备辅助模型（w2v-bert-2.0 / campplus / bigvgan / semantic codec）到 $CKPT_DIR/hf_cache"
    echo "  这些是 Web UI 首次启动必需的。正在预下载（体积大，请耐心等待）..."
    "$VENV_PY" - "$CKPT_DIR" <<'PYEOF' || true
import os, shutil, sys, traceback
from indextts.utils.model_download import ensure_models_available

ckpt = sys.argv[1]
w2v = os.path.join(ckpt, "hf_cache", "w2v-bert-2.0")

def clean_partial_w2v():
    # w2v-bert-2.0 must be a COMPLETE repo dir. A partial dir left by an
    # interrupted download would otherwise be mistaken for "already present"
    # (ensure_models_available only checks isdir/listdir) and crash at load
    # time with local_files_only=True. Clean it up so it re-downloads.
    if os.path.isdir(w2v):
        key = os.path.join(w2v, "model.safetensors")
        if not (os.path.isfile(key) and os.path.getsize(key) > 100 * 1024 * 1024):
            print(">> 正在清理不完整的 w2v-bert-2.0 目录（上次下载被中断）...")
            shutil.rmtree(w2v, ignore_errors=True)

def w2v_ready():
    key = os.path.join(w2v, "model.safetensors")
    return os.path.isfile(key) and os.path.getsize(key) > 100 * 1024 * 1024

def download_w2v_via_mirror():
    # China-friendly HuggingFace mirror (hf-mirror.com), resumable. Used when
    # the default source (ModelScope / HF direct) fails on the 4.3 GB weight.
    if w2v_ready():
        print(">> w2v-bert-2.0 已完整，跳过镜像下载。")
        return
    os.environ["USE_MODELSCOPE"] = "false"
    os.environ["HF_ENDPOINT"] = "https://hf-mirror.com"
    from huggingface_hub import snapshot_download
    print(">> 正在通过 hf-mirror.com 下载 w2v-bert-2.0（支持断点续传，请稍候）...")
    snapshot_download("facebook/w2v-bert-2.0", local_dir=w2v)
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
print(">> 所有辅助模型已就绪。")
PYEOF
    if aux_models_ready; then
      ok "辅助模型已就绪：$CKPT_DIR/hf_cache"
    else
      warn "辅助模型预下载未完成。Web UI 会在首次启动时重试。"
    fi
  fi
fi

# ---- 9. state ---------------------------------------------------------------------
SRC="${SRC:-auto}"
MODELS_READY="false"
if models_ready; then MODELS_READY="true"; fi
cat > "$STATE_FILE" <<EOF
{
  "installRoot": "$ROOT",
  "repoDir": "$REPO_DIR",
  "checkpointsDir": "$CKPT_DIR",
  "venvDir": "$REPO_DIR/.venv",
  "ffmpegBin": "",
  "extras": "$EXTRAS",
  "modelSource": "$SRC",
  "modelsReady": $MODELS_READY,
  "installedAt": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
ok "安装状态已保存到 $STATE_FILE"

echo ""
echo "======================================================================"
echo "  安装完成！"
echo "======================================================================"
echo "  启动 Web UI："
echo "      ./start-webui.sh"
echo "  然后在浏览器打开 http://127.0.0.1:7860"
echo ""
echo "  CLI 示例："
echo "      ./start-cli.sh --text '你好，这是 IndexTTS 2.5' --lang ZH"
echo ""
echo "  Web UI 附加开关：--fp16、--deepspeed、--accel、--cuda_kernel、--torch_compile"
echo "  更多镜像与排错请见 README.md。"
echo "======================================================================"

# 交互式运行（双击 / 控制台）时保持窗口不关闭；输出被重定向或 CI 时不阻塞。
if [[ -t 0 ]]; then
  echo ""
  echo "  安装已完成。按回车关闭本窗口。"
  read -r
fi

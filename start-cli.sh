#!/usr/bin/env bash
# IndexTTS-2.5 命令行推理示例（Linux/macOS）。
# 用法：
#   ./start-cli.sh --text '你好，世界' --lang ZH
#   ./start-cli.sh --text 'Hello world' --lang EN --ref-audio ./my_voice.wav --output ./out.wav
# 支持语言：ZH / EN / JA / ES / AR
set -euo pipefail

TEXT="${TEXT:-大家好，这是 IndexTTS 2.5 的语音合成测试。}"
LANG_CODE="${LANG_CODE:-ZH}"
REF_AUDIO="${REF_AUDIO:-}"
OUTPUT="${OUTPUT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)       TEXT="$2"; shift 2 ;;
    --lang)       LANG_CODE="$2"; shift 2 ;;
    --ref-audio)  REF_AUDIO="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    *) echo "未知选项：$1"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$ROOT/index-tts"
CKPT="$ROOT/checkpoints"
PY="$REPO/.venv/bin/python"

# 安装器可用时遵循 .install-state.json 记录的自定义路径。
if [[ -f "$ROOT/.install-state.json" ]] && command -v jq >/dev/null 2>&1; then
  st="$ROOT/.install-state.json"
  _r="$(jq -r '.repoDir // empty' "$st" 2>/dev/null || true)"
  if [[ -n "$_r" && -d "$_r" ]]; then REPO="$_r"; fi
  _c="$(jq -r '.checkpointsDir // empty' "$st" 2>/dev/null || true)"
  if [[ -n "$_c" && -d "$_c" ]]; then CKPT="$_c"; fi
  _v="$(jq -r '.venvDir // empty' "$st" 2>/dev/null || true)"
  if [[ -n "$_v" && -d "$_v" ]]; then PY="$_v/bin/python"; fi
fi

[[ -x "$PY" ]] || { echo "[FAIL] 未找到虚拟环境 Python：$PY。请先运行 ./install.sh。" >&2; exit 1; }
[[ -f "$CKPT/config.yaml" ]] || { echo "[WARN] 在 $CKPT 中未找到模型配置 config.yaml" >&2; exit 1; }

# 辅助模型（w2v-bert-2.0 约 4.3 GB、campplus、bigvgan、semantic codec）位于
# $CKPT/hf_cache，推理必需。先确认它们完整，避免首次运行静默触发大体积
# 下载、或把部分下载目录误判为"已存在"而崩溃。
aux_models_ready() {
  [[ -d "$CKPT/hf_cache" ]] || return 1
  local w2v="$CKPT/hf_cache/w2v-bert-2.0/model.safetensors"
  [[ -f "$w2v" ]] || return 1
  local sz; sz=$(stat -c%s "$w2v" 2>/dev/null || stat -f%z "$w2v" 2>/dev/null || echo 0)
  awk -v s="$sz" 'BEGIN { exit !(s > 100 * 1024 * 1024) }' || return 1
  for f in "campplus_cn_common.bin" "semantic_codec_model.safetensors" \
           "bigvgan/config.json" "bigvgan/bigvgan_generator.pt"; do
    [[ -f "$CKPT/hf_cache/$f" ]] || return 1
  done
  return 0
}
if ! aux_models_ready; then
  echo "======================================================================"
  echo "  $CKPT/hf_cache 中缺少辅助模型"
  echo "  （w2v-bert-2.0 约 4.3 GB、campplus、bigvgan、semantic codec）"
  echo "  现在开始下载——一次性下载，请稍候..."
  echo "======================================================================"
  (cd "$REPO" && "$PY" - "$CKPT" <<'PYEOF') || true
import os, shutil, sys, traceback
from indextts.utils.model_download import ensure_models_available

ckpt = sys.argv[1]
w2v = os.path.join(ckpt, "hf_cache", "w2v-bert-2.0")

def clean_partial_w2v():
    # w2v-bert-2.0 must be a COMPLETE repo dir. A partial dir left by an
    # interrupted download would otherwise be mistaken for "already present"
    # and crash at load time with local_files_only=True. Clean it up first.
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
    echo "[OK] 辅助模型已就绪。"
  else
    echo "[FAIL] 辅助模型下载失败。请检查网络后重新运行。" >&2
    exit 1
  fi
fi

if [[ -z "$REF_AUDIO" ]]; then
  REF_AUDIO="$REPO/examples/voice_01.wav"
fi
if [[ ! -f "$REF_AUDIO" ]]; then
  echo "[WARN] 未找到参考音频：$REF_AUDIO" >&2
  echo "       请用 --ref-audio <path.wav> 指定（3-10 秒清晰人声）。" >&2
fi
if [[ -z "$OUTPUT" ]]; then
  mkdir -p "$ROOT/output"
  OUTPUT="$ROOT/output/gen_$(date +%Y%m%d_%H%M%S).wav"
fi

export TOKENIZERS_PARALLELISM=false
echo "正在合成语音...（语言=$LANG_CODE，参考音频=$REF_AUDIO）"
cd "$REPO"
"$PY" indextts/infer_v2_5.py \
  --cfg_path "$CKPT/config.yaml" \
  --model_dir "$CKPT" \
  --prompt_wav "$REF_AUDIO" \
  --text "$TEXT" \
  --lang "$LANG_CODE" \
  --output "$OUTPUT"
echo "完成：$OUTPUT"

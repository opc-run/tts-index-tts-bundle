---
language:
  - zh
  - en
  - ja
  - es
  - ar
license: other
license_name: bilibili-model-license
license_link: LICENSE
library_name: indextts
pipeline_tag: text-to-speech
tags:
  - text-to-speech
  - tts
  - zero-shot
  - voice-cloning
  - multilingual
  - cross-lingual
  - emotion-controllable
---

# IndexTTS-2.5

IndexTTS-2.5 is a zero-shot text-to-speech model that clones a voice from a single
reference audio clip. It supports **Chinese, English, Japanese, Spanish and Arabic**,
with cross-lingual voice transfer and emotion control disentangled from timbre.

Compared with IndexTTS-2, it adds Japanese, Spanish and Arabic, infers faster, adds
speaking speed control, and improves controllability of Chinese Pinyin, English CMU
phonemes and Japanese Kana.

## Model Details

- **Developed by:** IndexTeam, Bilibili
- **Model type:** Autoregressive zero-shot TTS — GPT backbone, flow-matching
  speech-to-mel decoder, BigVGAN vocoder
- **Parameters:** ~0.8B (GPT backbone)
- **Languages:** Chinese, English, Japanese, Spanish, Arabic
- **Output:** 22.05 kHz waveform
- **License:** [bilibili Model Use License Agreement](LICENSE)
- **Repository:** [github.com/index-tts/index-tts](https://github.com/index-tts/index-tts)
- **Paper:** [arXiv:2601.03888](https://arxiv.org/abs/2601.03888)

## Getting Started

Requires Python 3.10–3.11, an NVIDIA GPU, and roughly 6 GB of VRAM for inference.

### Install

```bash
git clone https://github.com/index-tts/index-tts.git && cd index-tts
pip install -U uv
uv sync --all-extras
```

### Download the weights

```bash
# HuggingFace
uv tool install "huggingface-hub"
hf download IndexTeam/IndexTTS-2.5 --local-dir=checkpoints

# or ModelScope
uv tool install "modelscope"
modelscope download --model IndexTeam/IndexTTS-2.5 --local_dir checkpoints
```

Auxiliary models (w2v-bert-2.0, MaskGCT semantic codec, CAMPPlus, BigVGAN) are not
part of this repository; they are downloaded into `checkpoints/hf_cache/` on first run.

### Inference

```python
from indextts.infer_v2_5 import IndexTTS2

tts = IndexTTS2(cfg_path="checkpoints/config.yaml", model_dir="checkpoints", use_bf16=True)

# Voice cloning
tts.infer(
    spk_audio_prompt="prompt.wav",
    text="Hello, this is a voice cloning demo.",
    lang="EN",
    output_path="output.wav",
)

# Emotion control with an 8-float vector, in the order
# [happy, angry, sad, afraid, disgusted, melancholic, surprised, calm]
tts.infer(
    spk_audio_prompt="prompt.wav",
    text="快躲起来！是他要来了！",
    lang="ZH",
    output_path="output.wav",
    emo_vector=[0, 0, 0.8, 0, 0, 0, 0, 0],
)

# Pronunciation control: Pinyin, CMU phonemes, or Kana in <word|reading> form
tts.infer(
    spk_audio_prompt="prompt.wav",
    text="他在银<行|XING2>里<行|HANG2>走了半天。",
    lang="ZH",
    output_path="output.wav",
)

# Speaking speed: >1.0 slows down, <1.0 speeds up (valid range 0.5–2.0)
tts.infer(
    spk_audio_prompt="prompt.wav",
    text="大家好，欢迎来到IndexTTS。",
    lang="ZH",
    output_path="output.wav",
    duration_factor=1.2,
)
```

### Web UI

```bash
uv run webui.py
```

## Limitations

- Long text is split into segments and the pieces are concatenated with a short
  silence, so prosody is not modelled across a segment boundary.
- Emotion control from a text description needs the QwenEmotion model, which is
  loaded only when IndexTTS2 is constructed with `use_qwen_emo=True`. Passing
  `use_emo_text=True` without it raises at inference time.
- Enabling random sampling for emotion (`use_random=True`) reduces voice cloning
  fidelity.
- The model does not verify that the speaker in a reference clip consented to being
  cloned. Obtaining that consent is the user's responsibility, and all use is subject
  to the license terms.

## Citation

```bibtex
@misc{li2026indextts25technicalreport,
      title={IndexTTS 2.5 Technical Report},
      author={Yunpei Li and Xun Zhou and Jinchao Wang and Lu Wang and Yong Wu and Siyi Zhou and Yiquan Zhou and Yining Wang and Yaogen Yang and Zhetao Hu and Shiyao Duan and Jiacheng Xu and Bin Xia and Jingchen Shu},
      year={2026},
      eprint={2601.03888},
      archivePrefix={arXiv},
      primaryClass={cs.SD},
      url={https://arxiv.org/abs/2601.03888},
}
```

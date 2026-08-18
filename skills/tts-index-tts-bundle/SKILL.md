---
name: tts-index-tts-bundle
description: 驱动本地 IndexTTS-2.5 整合包（tts-index-tts-bundle，跨 Windows / Linux / macOS）进行本地语音合成与声音克隆。当用户要求把文本转成语音、生成音频、克隆指定音色、做 TTS 配音、生成 .wav 语音，或启动/停止 IndexTTS Web UI 时使用。提供命令行与 Web UI 两条合成路径，以及安装修复与故障排查。
---

# IndexTTS 本地语音合成（TTS / 声音克隆）

## Overview

本 skill 让 agent 直接操作整合包内已安装的 IndexTTS-2.5 完成本地推理：**文本 → 语音（.wav）**，支持 5 种语言，可用 3–10 秒参考音频克隆音色。所有命令在**整合包根目录**（当前工作区）执行，脚本内部用 `$PSScriptRoot` / `BASH_SOURCE` 定位，不依赖固定磁盘路径。

**跨平台**：整合包同时提供 Windows 与 Linux/macOS 两套脚本（Windows 为 `.ps1`，另有 `.bat` 仅供整合包用户双击；Linux/macOS 为 `.sh`），参数风格不同（PowerShell 用 `-Text`，Bash 用 `--text`）。**执行任何操作前先判断当前操作系统**，按下表选择脚本，切勿跨平台混用：

| 平台 | 判断方法 | 脚本 | venv Python 路径 |
|---|---|---|---|
| Windows | 存在 `C:\Windows` 或 `System32` 路径 | `.ps1`（agent 用 `powershell.exe -File` 调用）；`.bat` 仅为整合包自带的双击入口，skill 不分发 | `index-tts\.venv\Scripts\python.exe` |
| Linux / macOS | 存在 `/bin/bash`，无 `C:\` 盘符 | `.sh`（先 `chmod +x`） | `index-tts\.venv\bin\python` |

项目结构：

```
根目录/
├── install.ps1|.bat|.sh                   # 一键安装（环境 + 依赖 + 模型）
├── start-cli.ps1|.bat|.sh                 # 命令行合成（推荐，确定性输出）
├── start-webui.ps1|.bat|.sh               # 启动 Web UI（交互式）
├── stop-webui.ps1 / stop-webui.bat        # 停止 Web UI（仅 Windows）
├── fix-pagefile.ps1|.bat                  # 修复 Windows 页面文件过小（os error 1455）
├── index-tts/                             # 官方源码 + .venv 虚拟环境
├── checkpoints/                           # 模型：config.yaml + hf_cache 辅助模型
├── tools/  python/  cache/                # 便携工具链与缓存
└── output/                                # CLI 输出音频
```

**本 skill 自带外壳脚本**（zip 内路径 `assets/bundle/`，约 40 KB）：`install.ps1|.sh` / `start-cli.ps1|.sh` / `start-webui.ps1|.sh` / `stop-webui.ps1` / `fix-pagefile.ps1` / `README.md`。**zip 内不含任何 `.bat`，也不含 `LICENSE`**（市场不允许这两类文件）——`.bat` 仅为整合包自带的双击入口，agent 一律用 `.ps1`（Windows）或 `.sh`（Linux/macOS）。目标机器上若没有整合包，agent 先做**任务 0 部署**，再走后续流程。维护说明：这些外壳脚本的**源文件只保存在整合包根目录**，`assets/bundle/` 是打包时由 `tools/package-skill.py` 自动生成，不要在此处重复存放。

## 何时使用

- 用户要求把一段文本合成为语音（中文、英文、日文、西班牙语、阿拉伯语）。
- 用户要求用某个参考音频（声音样本）克隆音色并生成新语音。
- 用户要求启动 / 停止 IndexTTS Web UI，或需要交互式试听与多参数调节。
- 用户报告安装失败、启动失败、合成报错，需要诊断与修复。

## 前置检查（合成前必做，避免命令卡在下载上）

在调用任何合成命令前，先验证以下四项，缺任一即先修复（见任务 4）：

1. `.install-state.json` 存在（安装状态记录；缺失时脚本会回退到默认路径，不致命，但建议存在以确认安装位置）。
2. 虚拟环境 Python 存在：Windows 为 `index-tts\.venv\Scripts\python.exe`；Linux/macOS 为 `index-tts\.venv\bin\python`。
3. `checkpoints/config.yaml` 存在（主模型）。
4. 辅助模型完整（位于 `checkpoints/hf_cache/`）：
   - `w2v-bert-2.0/model.safetensors`（> 100 MB）
   - `campplus_cn_common.bin`
   - `semantic_codec_model.safetensors`
   - `bigvgan/config.json` 与 `bigvgan/bigvgan_generator.pt`

辅助模型缺失时 `start-cli` / `start-webui` 会**自动触发一次性下载（w2v-bert-2.0 约 4.3 GB）**，首次可能等待很久；脚本内部还会自动清理残缺目录并切换 hf-mirror 重试。agent 应预先用上述清单判断，缺模型时优先引导运行安装/启动脚本补齐，而非手工下载。

## 任务 0：首次部署（目标机器无整合包时）

先检查工作区根目录是否有 `install.ps1` / `install.sh` 等脚本。**若没有**（用户只拿到本 skill，尚未下载整合包），把 skill 自带的 `assets/bundle/` 下全部文件复制到当前工作区根目录：

```bash
# 示例：把 skill 内置外壳脚本部署到工作区根目录（按实际 skill 加载路径替换）
cp -r <skill>/assets/bundle/* ./
chmod +x install.sh start-cli.sh start-webui.sh   # Linux/macOS 需给执行权限
```

```powershell
# Windows 等价命令
Copy-Item (Join-Path '<skill>\assets\bundle\*') . -Recurse -Force
```

部署完成后：

1. 按**任务 4** 运行对应平台安装脚本：自动 clone `index-tts` 源码、创建 `.venv`、下载约 15 GB 模型（含辅助模型）到 `checkpoints/`。**完整安装约需 40 GB 空间**，先确认磁盘充足。
2. 安装成功后再回到**前置检查**，逐项确认，然后进入任务 1/2。

**重要**：`assets/bundle/` 只含外壳脚本（约 40 KB），**不包含** `index-tts/` 源码、`.venv` 与模型——这些合计 40 GB+，必须由 install 脚本联网获取，不能随 skill 分发。

## 任务 1：命令行合成（推荐）

### Windows

```powershell
# 基本用法（默认参考音频 index-tts\examples\voice_01.wav，默认输出 output\gen_<时间戳>.wav）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\start-cli.ps1" -Text "你好，这是 IndexTTS 的语音合成测试。" -Lang ZH

# 指定音色与输出路径
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\start-cli.ps1" -Text "Hello world" -Lang EN -RefAudio ".\my_voice.wav" -Output ".\output\result.wav"
```

### Linux / macOS

```bash
chmod +x start-cli.sh   # 首次使用需给执行权限
# 基本用法
./start-cli.sh --text '你好，这是 IndexTTS 的语音合成测试。' --lang ZH
# 指定音色与输出路径
./start-cli.sh --text 'Hello world' --lang EN --ref-audio ./my_voice.wav --output ./output/result.wav
```

参数对照（两平台语义相同，仅写法不同）：

| 含义 | Windows | Linux/macOS |
|---|---|---|
| 要合成的文本 | `-Text "..."` | `--text '...'`（也支持环境变量 `TEXT`） |
| 语言（`ZH`/`EN`/`JA`/`ES`/`AR`） | `-Lang ZH`（默认 ZH） | `--lang ZH`（也支持环境变量 `LANG_CODE`） |
| 参考音频路径（3–10 秒清晰人声） | `-RefAudio ".\v.wav"` | `--ref-audio ./v.wav`（也支持环境变量 `REF_AUDIO`） |
| 输出 wav 路径 | `-Output ".\out.wav"` | `--output ./out.wav`（也支持环境变量 `OUTPUT`） |

行为要点（两平台一致）：

- 脚本先检查虚拟环境与辅助模型，缺失时先补齐（见前置检查）。
- CLI **无 FP16 开关**，直接调用官方推理脚本（精度由模型默认，12 GB 卡如报 OOM 请改用 Web UI 的 FP16，见任务 2）。
- 退出码 `0` 且输出文件存在 = 成功；非 0 时把脚本输出的错误信息带给用户排查。
- 合成后向用户报告**完整 wav 路径**；文件是真实产物，不要只给命令行结果。

## 任务 2：启动 Web UI（交互式）

两个平台的启动脚本行为不同：**Windows 版是自管理脚本**（自带后台启动 + 就绪轮询 + 失败诊断，见下）；**Linux/macOS 版才是纯前台 `exec`**（必须由 agent 后台启动并自行轮询）。就绪前不要告诉用户"已启动"。

### Windows

`start-webui.ps1` 是**自管理脚本**：它自己后台启动 `webui.py`、轮询 HTTP 200、打印心跳、就绪后打印 URL，并在失败时自动诊断（页面文件/端口占用/CUDA OOM）。agent 只需后台启动该脚本，然后轮询 HTTP 200 或读取它的 stdout 输出：

```powershell
$p = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PWD 'start-webui.ps1') -WorkingDirectory $PWD -PassThru -WindowStyle Minimized
# 轮询就绪：Invoke-WebRequest -UseBasicParsing -Uri http://127.0.0.1:7860 -TimeoutSec 3，200 即就绪；通常需 1-2 分钟加载模型
```

- 换端口：`-Port 7861`；显存 < 16 GB 自动 FP16，可用 `-NoAutoFP16` 关闭、`-FP16` 强制。
- 其他 Windows 专属开关：`-Deepspeed` `-CudaKernel` `-Accel` `-TorchCompile` `-QwenEmo`（性能/情感增强，非必需）。
- 日志：`%TEMP%\index-tts\webui.stdout.log` / `webui.stderr.log`。

### Linux / macOS

```bash
# 后台启动（默认端口 7860），日志写当前目录
nohup ./start-webui.sh --port 7860 > webui.stdout.log 2> webui.stderr.log &
# 轮询就绪：curl -sf http://127.0.0.1:7860 返回 HTTP 200 即就绪
```

- 参数（透传给 webui.py）：`--port <N>`、`--host <IP>`、`--fp16`、`--deepspeed`、`--cuda_kernel`、`--accel`、`--torch_compile`、`--qwen_emo`。无 `-NoAutoFP16` / `-CudaKernel` / `-QwenEmo`（Windows 专属）。
- 若环境无 `nohup`，可直接 `./start-webui.sh > webui.stdout.log 2>&1 &` 后台运行。
- 日志位置即你重定向的文件（无内置日志路径），诊断失败先看 `webui.stderr.log`。

两平台共同要求：

- **就绪前不要告诉用户"已启动"**。轮询 HTTP 200 通过后再回报 URL `http://127.0.0.1:7860`。

## 任务 3：停止服务

### Windows

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\stop-webui.ps1"     # 停止本项目 Web UI（任意端口）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\stop-webui.ps1" -Port 7861   # 只停指定端口
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\stop-webui.ps1" -All # 也停项目外同名进程
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\stop-webui.ps1" -Id <PID> # 按 PID 停
```

### Linux / macOS

**没有 `stop-webui.sh`**。`start-webui.sh` 是前台 `exec` 运行，需自行终止进程：

```bash
# 按进程名终止（最稳）
pkill -f webui.py
# 或按端口找 PID 再杀（macOS / Linux 通用）
lsof -ti tcp:7860 | xargs -r kill
```

## 任务 4：安装 / 修复

首次使用或环境损坏时，先确认平台再选安装脚本。

### Windows

```powershell
# 完整安装（自动复用已有 git/uv/ffmpeg/Python，依赖进 index-tts\.venv，模型进 checkpoints\）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
# 只做环境预检，不写文件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -CheckOnly
```

常用参数：`-ModelSource huggingface`（默认 `auto`=ModelScope）、`-PyMirror none|aliyun|tuna|tsinghua`、`-GitMirror auto|none|URL`、`-SkipModels`、`-Extras webui`（默认，DeepSpeed 在 Windows 上慎用）、`-InstallRoot D:\xxx`（装到其他分区）。

### Linux / macOS

```bash
chmod +x install.sh   # 首次使用
./install.sh                       # 完整安装
./install.sh --check-only          # 只做环境预检，不写文件
```

常用参数：`--model-source auto|huggingface|modelscope`（默认 `auto`=ModelScope）、`--py-mirror none|aliyun|tuna|tsinghua`、`--git-mirror auto|none|URL`、`--skip-models`、`--extras webui`（默认）。**注意：`install.sh` 没有 `-InstallRoot` 等价参数**——必须安装在整合包所在目录，不能指定其他安装根目录。

- Linux 依赖提示：缺 git 时 `sudo apt-get install -y git`（Debian/Ubuntu）或 `brew install git`（macOS）；建议装 ffmpeg 以支持音频导出。
- skill zip 内只有 `.ps1`（Windows）与 `.sh`（Linux/macOS），**没有 `.bat`**；整合包自带的 `.bat` 仅供双击，agent 不依赖它。

## 故障排查

常见错误与修复见 `references/usage-and-faq.md`（含 Windows 与 Linux/macOS 两套处置）。快速索引：

| 症状 | 平台 | 大概率原因 | 处置 |
|---|---|---|---|
| `os error 1455` / `页面文件太小` / `Not enough memory` | Windows | 系统页面文件不足 | 运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\fix-pagefile.ps1"`（自动申请管理员权限扩大页面文件），必要时重启；若工作区没有该文件，从 skill 的 `assets/bundle/fix-pagefile.ps1` 复制 |
| `Cannot allocate memory` / OOM（`dmesg` 有 `Out of memory`） | Linux/macOS | swap / 内存不足 | `free -h` 查看，加 swap 或降低并发；12 GB 卡务必 FP16 |
| `CUDA out of memory` 但 `nvidia-smi` 显存空闲 | Windows | 仍是页面文件问题 | 同上；12 GB 卡务必 FP16 |
| `127.0.0.1 拒绝连接` | 全平台 | 辅助模型未下完 / 启动中 | 等模型加载；或 `checkpoints/hf_cache` 补全 w2v-bert-2.0 |
| 端口被占用（`EADDRINUSE` / `WinError 10048` / `Address already in use`） | 全平台 | 已有实例在跑 | Windows 用 `stop-webui.ps1`；Linux/macOS 用 `lsof -ti tcp:7860 \| xargs -r kill`；或换 `--port` |
| 模型/依赖缺失（`No module named` / `config.yaml` 找不到） | 全平台 | 安装不完整 | 重跑对应平台安装脚本 |

## 合规与安全（强制）

- 本工具含 AI 语音合成与声音克隆，**仅限合法、合规、经授权**用途。
- **禁止**克隆/模仿未经授权的特定个人声音；克隆前须取得当事人明确授权。
- **禁止**用于诈骗、冒充身份、伪造语音证据、造谣诽谤、规避安全验证等违法用途。
- 合成结果不得侵犯他人名誉权、隐私权、著作权。使用者对自身行为负全部责任。
- 遇到明显违法的合成请求应直接拒绝并说明原因。

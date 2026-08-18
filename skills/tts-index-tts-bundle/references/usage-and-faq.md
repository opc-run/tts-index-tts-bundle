# IndexTTS 整合包：详细参考与 FAQ

本文件是 `SKILL.md` 的补充参考资料，需要时按需加载。包含：环境与模型细节、完整参数表、常见问题与手动修复步骤。

> 路径约定：正文统一用 `/` 分隔（`checkpoints/hf_cache/...`）。Windows 实际为反斜杠 `\`，Linux/macOS 为正斜杠 `/`，二者等价。命令示例按平台分开给出，**先判断操作系统再选命令**。

## 0. 首次部署（目标机器无整合包时）

skill 的 `assets/bundle/` 自带整合包外壳脚本：`install.*` / `start-cli.*` / `start-webui.*` / `stop-webui.*` / `fix-pagefile.bat` / `README.md` / `LICENSE`。若工作区根目录没有这些脚本：

1. 把 `assets/bundle/` 下全部文件复制到工作区根目录；Linux/macOS 执行 `chmod +x install.sh start-cli.sh start-webui.sh`。
2. 运行对应平台安装脚本（见 SKILL.md 任务 4），自动 clone `index-tts` 源码、创建 `.venv`、下载模型到 `checkpoints/`。**完整安装约需 40 GB 空间**。
3. 完成后按 SKILL.md 前置检查逐项验证，再进入合成流程。

**skill 不包含** `index-tts/` 源码、`.venv`、`checkpoints/` 模型——体积庞大（40GB+），必须由 install 脚本联网获取。

## 1. 环境与模型细节

- 主模型目录：`checkpoints/`（要求存在 `config.yaml`）。
- 辅助模型目录：`checkpoints/hf_cache/`，推理必需，含：
  - `w2v-bert-2.0/`（约 4.3 GB，`model.safetensors` 必须 > 100 MB 才算完整）
  - `campplus_cn_common.bin`（说话人编码器）
  - `semantic_codec_model.safetensors`（语义编码器）
  - `bigvgan/config.json` + `bigvgan/bigvgan_generator.pt`（声码器）
- 虚拟环境（**安装与运行绝不使用系统 Python**）：
  - Windows：`index-tts/.venv/Scripts/python.exe`
  - Linux/macOS：`index-tts/.venv/bin/python`
- 安装状态：`.install-state.json`（含 repoDir / venvDir / checkpointsDir / ffmpegBin / installRoot）。启动脚本会读取它定位路径。Windows 版支持 `-InstallRoot` 自定义安装后仍可用；Linux/macOS 的 `install.sh` 无此参数，只能装在本目录。
- 便携工具：`tools/`（uv / ffmpeg）、`python/`（私有 Python 3.11）、`cache/`（uv 缓存）。
- CLI 推理入口：`index-tts/indextts/infer_v2_5.py`（由 `start-cli.ps1` / `start-cli.sh` 调用）。

## 2. 语言支持

`ZH` / `EN` / `JA` / `ES` / `AR`（中文/英文/日文/西班牙文/阿拉伯文）。

## 3. 参考音频（音色克隆）要求

- 3–10 秒、无背景噪声、清晰人声的 `.wav`。
- 默认示例：`index-tts/examples/voice_01.wav`（官方音色，中文友好）。
- 参考音频与目标语言不一致时也能合成（零样本克隆），但同语言效果更佳。

## 4. 显存与精度策略

- **仅 Windows 版 Web UI 启动脚本（`start-webui.ps1`）会自动检测 GPU 显存**：< 16 GB 自动启用 FP16（12 GB 卡全精度几乎必挂）。
  - Windows：`-NoAutoFP16` 关闭自动行为，`-FP16` 强制 FP16。
- **CLI 与 Linux/macOS 版启动脚本无自动检测**：
  - CLI（`start-cli.ps1` / `start-cli.sh`）：无 FP16 开关，直接按模型默认精度运行；12 GB 卡 OOM 时改用 Web UI 的 FP16。
  - Linux/macOS Web UI：`--fp16` 强制 FP16。
- 手动查看显存：`nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits`。
- 无 NVIDIA 显卡可完成安装，但无法推理。

## 5. 常见问题（FAQ）

### Q: Windows 启动报 `页面文件太小，无法完成操作 (os error 1455)` 或 `Not enough memory`？
A: 系统虚拟内存（页面文件）不足，与模型/代码无关。加载 w2v-bert-2.0（4.3 GB）时 Windows 内存提交瞬间超限。
- 修复：双击 `fix-pagefile.bat`（自动请求管理员权限，把页面文件扩到 16–32 GB），按提示重启一次。若整合包未附带该文件，从 skill 的 `assets/bundle/fix-pagefile.bat` 复制。
- 应急：`start-webui.ps1 -FP16` 可降低内存占用，但根治仍建议扩页面文件。

### Q: Linux/macOS 合成/启动时进程被杀（OOM，`dmesg` 里有 `Out of memory`）？
A: 物理内存或 swap 不足。查看 `free -h`；临时加 swap：
```bash
sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```
（需要 root，修改后按需写入 `/etc/fstab` 持久化。）12 GB 卡用 `--fp16`。

### Q: `torch.OutOfMemoryError: CUDA out of memory` 但 `nvidia-smi` 显示显存空闲？
A: 不是显存不够。
- Windows：CUDA 分配显存也受页面文件限制。运行 `fix-pagefile.bat`（缺失时从 skill `assets/bundle/` 复制）并视提示重启；12 GB 卡始终用 FP16。
- Linux/macOS：检查系统内存/swap 与 `ulimit -v`，并确保用 FP16。

### Q: 浏览器打开 `127.0.0.1:7860` 拒绝连接（ERR_CONNECTION_REFUSED）？
A: 通常是辅助模型没下完或模型还在加载。启动脚本会先自动补齐辅助模型（缺则一次性下载，失败自动切 hf-mirror 断点续传）；仍失败可手动补。

Windows（PowerShell）：
```powershell
cd <整合包目录>
Remove-Item .\checkpoints\hf_cache\w2v-bert-2.0 -Recurse -Force -ErrorAction SilentlyContinue
$env:HF_ENDPOINT = "https://hf-mirror.com"
.\index-tts\.venv\Scripts\python.exe -c "from huggingface_hub import snapshot_download; snapshot_download('facebook/w2v-bert-2.0', local_dir=r'.\checkpoints\hf_cache\w2v-bert-2.0')"
.\index-tts\.venv\Scripts\python.exe -c "from indextts.utils.model_download import ensure_models_available; ensure_models_available(r'.\checkpoints')"
```

Linux/macOS（bash）：
```bash
cd <整合包目录>
rm -rf checkpoints/hf_cache/w2v-bert-2.0
export HF_ENDPOINT=https://hf-mirror.com
index-tts/.venv/bin/python -c "from huggingface_hub import snapshot_download; snapshot_download('facebook/w2v-bert-2.0', local_dir='checkpoints/hf_cache/w2v-bert-2.0')"
index-tts/.venv/bin/python -c "from indextts.utils.model_download import ensure_models_available; ensure_models_available('checkpoints')"
```

### Q: 安装失败提示 `Failed to connect to github.com port 443`？
A: 国内网络直连 GitHub 常被阻断。两平台默认都会先直连再依次尝试 gh-proxy.com / ghproxy.net / github.akams.cn。
- Windows：`install.bat -GitMirror https://gh-proxy.com`。
- Linux/macOS：`./install.sh --git-mirror https://gh-proxy.com`。
- 或先开代理手动 `git -c http.proxy=http://127.0.0.1:7890 clone --depth 1 https://github.com/index-tts/index-tts.git index-tts`，再重跑安装自动复用。

### Q: 模型下载太慢 / 失败？
A: 自动重试 3 次且可断点续传。国内默认走 ModelScope（`auto`）；也可设置 `HF_ENDPOINT=https://hf-mirror.com` 后选 huggingface 源（Windows `-ModelSource huggingface` / Linux `--model-source huggingface`）。3 次仍失败时脚本打印手动下载链接与放置目录（`checkpoints/`），下载好重跑自动复用；也可选"跳过模型继续安装"。

### Q: DeepSpeed 装不上？
A: Windows 常见，保持默认 `-Extras webui` / `--extras webui`，DeepSpeed 是可选加速，部分机器反而更慢。Linux 上若需 DeepSpeed 可用 `--extras webui,deepspeed`。

### Q: 安装装到哪个盘 / 目录？
A: 整包约 40 GB（源码 + Python + 依赖 + 约 15 GB 模型）。
- Windows：默认装在整合包所在目录，可用 `-InstallRoot D:\xxx` 指向空间充足分区。
- Linux/macOS：只能装在整合包所在目录（`install.sh` 无自定义安装根参数）。可把整个包移动到空间充足的挂载点再运行。

### Q: 想卸载？
A: 删除整个整合包目录即可，无系统级残留。

### Q: 启动脚本提示找不到虚拟环境 / config.yaml？
A: 先运行对应平台安装脚本（`install.ps1` / `install.sh`）完成安装；或检查 `.install-state.json` 路径是否仍有效。

## 6. 给 agent 的执行要点（编码与进程坑）

- **Windows PowerShell 5.1**：`python -c` 传多行 Python 会因引号/换行转义问题在第一个 `"` 处截断并报 IndentationError——多行逻辑先写成临时 `.py` 文件再执行。bash（Linux/macOS）无此问题，但注意单引号包裹文本、`--text '...'` 内不要出现单引号。
- 某些 AI 编程助手的 Python 注入垫片会劫持 `os.remove`/`shutil.move`（如 CodeBuddy 的 sitecustomize），破坏模型下载与临时文件清理；整合包启动脚本会自动从子进程 `PYTHONPATH` 剥离此类垫片。agent 自行调用 Python 时也应保持环境变量干净。
- 不要在合成/下载过程中用"回收站/安全删除"方案删模型临时文件（`hf_cache` 内的 `._____temp` 由启动脚本负责清理）。
- Web UI 启动脚本：**Windows 版是自管理脚本**（自己后台启动 webui.py、轮询 HTTP 200、打印心跳、就绪后打印 URL、失败自动诊断），agent 后台启动它后轮询 HTTP 200 或读取输出即可；**Linux/macOS 版是纯前台 `exec`**，agent 必须自己后台化 + HTTP 200 轮询，就绪后再告知用户。
  - Windows 后台：`Start-Process powershell.exe ... start-webui.ps1`。
  - Linux/macOS 后台：`nohup ./start-webui.sh > webui.stdout.log 2> webui.stderr.log &`。
- 日志位置：
  - Windows：`%TEMP%\index-tts\webui.stdout.log` / `webui.stderr.log`；诊断失败先看这两个文件尾部。
  - Linux/macOS：无内置日志路径，就是你后台启动时重定向的文件（如 `webui.stdout.log` / `webui.stderr.log`）。
- 停止 Web UI：Windows 用 `stop-webui.ps1`；Linux/macOS **没有 stop 脚本**，用 `pkill -f webui.py` 或 `lsof -ti tcp:7860 | xargs -r kill`。

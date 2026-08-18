# IndexTTS-2.5 一键安装整合包

[IndexTTS-2.5](https://github.com/index-tts/index-tts)（B 站 IndexTTS 团队开源的工业级可控零样本语音合成系统）的 **Windows / Linux / macOS 一键安装整合包**。

目标：**一条命令装好、尽量少动宿主电脑**。

> **⚠️ 重要提示（请先阅读）**：本整合包包含 AI 语音合成（含声音克隆）能力，仅限**合法、合规、经授权**的用途。禁止利用本工具伪造他人声音实施诈骗、冒充、造谣诽谤或制作任何违反法律法规的内容。合成或克隆他人声音前，必须获得当事人明确授权。使用者须对自身使用行为负全部责任。详见文末[免责声明](#免责声明)。

- **避免重复安装**：先检测宿主机已有的 git / uv / ffmpeg / Python 3.10/3.11，已存在则直接复用，绝不重复安装；缺失时才补装，且**尽量装入整合包自身目录**，不污染系统。
- **依赖完全隔离**：所有 Python 依赖装在 `index-tts/.venv` 内，不碰系统 Python。
- **模型目录预留**：模型下载到整合包内的 `checkpoints/` 文件夹；你也可以手动下载后放入该目录，脚本检测到即自动复用。

---

## 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10/11（PowerShell 5.1+）、或 Linux / macOS |
| GPU | NVIDIA 显卡，显存 **≥ 6 GB**（BF16 推理） |
| 磁盘 | 放入可用空间 **≥ 40 GB** 的分区：源码 + Python + 依赖 + 约 15 GB 模型 |
| 网络 | 需能访问 GitHub、PyPI（国内可加镜像参数） |
| 必装工具 | git（脚本可自动通过 winget 安装） |

> 无 NVIDIA 显卡也能完成安装，但无法推理。

---

## 快速开始

### Windows

把整合包整个文件夹复制/解压到**可用空间 ≥ 40 GB** 的分区（如 `D:\IndexTTS-2.5-bundle`），然后：

```powershell
# 方式 A（推荐）：直接双击 install.bat —— .ps1 双击会打开记事本，
# 所以提供了 .bat 包装脚本（自动绕过执行策略调用 install.ps1）
# 方式 B：命令窗口执行
cd D:\IndexTTS-2.5-bundle   # 换成你实际放置的目录
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> `install.bat` 会透传参数，需要自定义时可双击后追加，或在命令窗口运行 `install.bat -CheckOnly`、`install.bat -ModelSource huggingface` 等。

安装完成后启动 Web UI：

```powershell
# 直接双击 start-webui.bat，或在命令窗口执行：
.\start-webui.bat
```

浏览器打开 <http://127.0.0.1:7860>。

命令行推理：

```powershell
# 直接双击 start-cli.bat（用默认文本），或在命令窗口执行：
.\start-cli.bat -Text "你好，这是 IndexTTS 2.5 的测试。" -Lang ZH
```

> 三个 `.bat`（`install.bat` / `start-webui.bat` / `start-cli.bat`）都可以**双击运行**，并支持在命令窗口追加参数透传。

### Linux / macOS

```bash
cd <整合包目录>
chmod +x install.sh start-webui.sh start-cli.sh
./install.sh            # 可选参数见下表
./start-webui.sh        # 启动后访问 http://127.0.0.1:7860
./start-cli.sh --text "你好，世界" --lang ZH
```

### 常用参数

| 参数 | 说明 |
|---|---|
| `-ModelSource huggingface` / `--model-source huggingface` | 模型从 HuggingFace 下载（默认 `auto` = ModelScope，国内更快） |
| `-PyMirror aliyun` / `--py-mirror aliyun` | 依赖安装使用国内 PyPI 镜像（`aliyun` / `tuna` / `tsinghua`） |
| `-GitMirror auto` / `--git-mirror auto` | 克隆源码时的 GitHub 加速镜像：`auto`（默认，先直连，失败自动换镜像）/ `none`（仅直连）/ 镜像前缀 URL / 完整克隆 URL |
| `-Extras webui,deepspeed` / `--extras webui,deepspeed` | 额外功能（默认 `webui`；Windows 上 deepspeed 可能编译失败，慎用） |
| `-SkipModels` / `--skip-models` | 跳过模型下载（仅装代码与依赖） |
| `-SkipFFmpeg` | 跳过便携 ffmpeg 下载 |
| `-CheckOnly` / `--check-only` | 只做环境预检，不写任何文件 |
| `-InstallRoot D:\IndexTTS-2.5-bundle` | 指定安装根目录（默认就是整合包所在目录；可指向空间充足的其他分区） |

Web UI 附加开关：`-Deepspeed`、`-CudaKernel`、`-Accel`、`-TorchCompile`、`-QwenEmo`、`-Port 7861`、`-NoAutoFP16`。

> **FP16 自动启用**：启动时若检测到 GPU 显存不足 16 GB，会自动以 FP16（半精度）加载模型，无需手动加参数；显存 ≥16 GB 才默认 FP32。想关闭自动行为可用 `-NoAutoFP16`，强制 FP16 仍可用 `-FP16`。

---

## 工作原理（为什么“不重复安装”）

```
整合包目录/
├── install.ps1 / install.bat / install.sh   # 一键安装（Windows 可双击 .bat）
├── start-webui.ps1/.bat/.sh                 # 启动 Web UI（Windows 可双击 .bat）
├── start-cli.ps1/.bat/.sh                   # 命令行推理（Windows 可双击 .bat）
├── checkpoints/                 # ★ [预建] 模型目录（自动下载 / 手动放入）
├── index-tts/                   # [安装时生成] 官方源码 + .venv 虚拟环境
├── tools/                       # [预建] 缺失时下载便携 uv / ffmpeg
├── python/                      # [预建] 缺失时安装私有 Python 3.11
├── cache/                       # [预建] uv 包缓存（避免占系统盘）
├── output/                      # [预建] CLI 输出音频
└── .install-state.json          # [安装时生成] 安装状态记录
```

> `checkpoints/`、`tools/`、`python/`、`cache/`、`output/` 均已随整合包**预建**并附说明文档（README），安装脚本会自动往里面填充内容，无需手动创建；`index-tts/` 与 `.install-state.json` 由安装脚本生成。

安装脚本按顺序执行：

1. **环境检测（复用优先）**：`git`、`uv`、`ffmpeg`、Python 3.10/3.11 —— 已存在就直接用；
   - `uv` 缺失 → 下载便携版到 `tools/uv`（不写系统 PATH）
   - `ffmpeg` 缺失 → 下载便携版到 `tools/ffmpeg`
   - Python 版本不符 → 用 `uv python install` 装入 `python/`，**不碰系统 Python**
2. **克隆源码**：`git clone --depth 1` 到 `index-tts/`，再次运行会自动 `git pull`。直连 GitHub 失败（国内网络常见）时自动尝试国内加速镜像；仍失败会打印手动克隆/代理方法。
3. **依赖安装**：`uv sync --extra webui`，全部依赖进 `index-tts/.venv`；`uv` 缓存指向 `cache/`。
4. **模型就位**：若 `checkpoints/config.yaml` 存在则复用；否则按 `-ModelSource` 下载到 `checkpoints/`。
5. **写出状态**：`.install-state.json` 记录路径，供启动脚本读取。

> 全程使用**会话级环境变量**（`UV_CACHE_DIR` 等），不写注册表、不改用户 PATH、不碰系统 Python。

---

## 常见问题（FAQ）

**Q：装到哪个盘比较好？**
A：整合包内容默认装在**整合包所在目录**，整包约需 40 GB。建议放到**可用空间 ≥ 40 GB** 的分区；安装时脚本会提示当前磁盘空间，并指出当前机器空间最充足的分区。

**Q：安装失败提示 CUDA 错误？**
A：需要 NVIDIA CUDA Toolkit 12.8 或更新版本（torch 自带 CUDA 运行库，多数情况无需单独安装；仍报错时请安装 CUDA Toolkit）。

**Q：DeepSpeed 装不上？**
A：Windows 上常见。保持默认 `-Extras webui` 即可，DeepSpeed 是可选加速，部分机器反而更慢。

**Q：报错 `Failed to connect to github.com port 443` / 克隆源码失败？**
A：国内网络直连 GitHub 常被阻断。脚本默认 `-GitMirror auto`：先试直连，失败自动依次尝试 `gh-proxy.com` / `ghproxy.net` / `github.akams.cn` 加速镜像。仍失败时：
- 手动指定镜像：`install.bat -GitMirror https://gh-proxy.com`（或完整克隆 URL `-GitMirror https://gh-proxy.com/https://github.com/index-tts/index-tts.git`）；
- 或先开好代理再手动克隆：`git -c http.proxy=http://127.0.0.1:7890 clone --depth 1 https://github.com/index-tts/index-tts.git index-tts`，完成后重新运行安装脚本即可自动复用。

**Q：模型下载太慢 / 失败？**
A：脚本会自动**重试 3 次**（已下载的部分可断点续传）。国内网络建议默认走 ModelScope；也可设置 `HF_ENDPOINT=https://hf-mirror.com` 后选 HuggingFace 重试。3 次仍失败时，脚本会打印**手动下载链接**（ModelScope / HuggingFace / HF 镜像）和**放置目录**（`checkpoints/`），下载好后重新运行即可自动复用；也可以选"跳过模型继续安装"，之后手动放入模型。

**Q：启动 Web UI 报错 `127.0.0.1 拒绝连接`（ERR_CONNECTION_REFUSED）？**
A：通常是**辅助模型没下载完**。除主模型（`checkpoints/`）外，Web UI 首次启动还需要 `w2v-bert-2.0`（约 4.3 GB）等辅助模型，它们放在 `checkpoints/hf_cache/`。现在安装脚本会在安装阶段**预下载辅助模型**；启动脚本（`start-webui.bat`）也会在启动前自动检测并补齐，且会自动清理中断留下的残缺目录；若默认下载源（ModelScope / HuggingFace 直连）失败，会自动切换到 `hf-mirror.com` 镜像重试（可断点续传）。仍失败时可手动补下（PowerShell）：

```powershell
cd <整合包目录>
Remove-Item .\checkpoints\hf_cache\w2v-bert-2.0 -Recurse -Force -ErrorAction SilentlyContinue
$env:HF_ENDPOINT = "https://hf-mirror.com"
.\index-tts\.venv\Scripts\python.exe -c "from huggingface_hub import snapshot_download; snapshot_download('facebook/w2v-bert-2.0', local_dir=r'.\checkpoints\hf_cache\w2v-bert-2.0')"
.\index-tts\.venv\Scripts\python.exe -c "from indextts.utils.model_download import ensure_models_available; ensure_models_available(r'.\checkpoints')"
```

下载完成后重新双击 `start-webui.bat` 即可。

**Q：启动 Web UI 报错 `页面文件太小，无法完成操作 (os error 1455)`？**
A：是**系统虚拟内存（页面文件）不足**，不是模型或代码问题。加载 `w2v-bert-2.0`（约 4.3 GB）等大模型时，Windows 内存提交会瞬间超限。本机页面文件若为固定大小且不自动增长（`AutomaticManagedPagefile=False`），更容易触发。
- 修复：双击运行 `fix-pagefile.bat`（自动请求管理员权限），把页面文件扩大到 16–32 GB；脚本会检测是否生效，若未生效按提示重启一次（Windows 扩容页面文件大多在线生效，部分机器需重启）。
- 或手动设置（管理员 PowerShell）：`wmic pagefileset where "name='D:\\pagefile.sys'" set InitialSize=16384,MaximumSize=32768`。
- 应急：可用 `start-webui.bat -FP16` 降低内存占用，但根治仍建议扩大页面文件。

**Q：报错 `torch.OutOfMemoryError: CUDA out of memory`，但 `nvidia-smi` 显示显存还有很多空闲？**
A：**这不是显存不够**。Windows 上 CUDA 分配显存也受系统虚拟内存（页面文件）限制——页面文件太小会导致 CUDA 分配在明明有空闲显存时失败。按上一条运行 `fix-pagefile.bat` 并（视提示）重启即可。另外 **12GB 显存（如 RTX 3060）无需手动加参数**——`start-webui.bat` 检测到显存不足 16GB 会自动以 FP16 模式启动，全精度(FP32)在 12GB 卡上基本必挂。

**Q：能先下载好模型再安装吗？**
A：可以。手动把 IndexTTS-2.5 放入 `checkpoints/`（见该目录下 README），安装脚本检测到 `config.yaml` 即跳过下载。

**Q：想卸载？**
A：删除整个整合包目录即可（所有内容都在其中，无系统级残留；如 winget 自动装过 git，可自行卸载）。

**Q：启动脚本找不到虚拟环境？**
A：请先运行 `install.ps1` / `install.sh` 完成安装，或检查 `.install-state.json` 中的路径是否仍有效。

---

## 许可

- 本整合包的脚本与文档：**MIT License**（见 `LICENSE`）。
- IndexTTS-2.5 本体及模型权重遵循 **bilibili Model Use License Agreement**（`bilibili IndexTTS Model License`），使用前请阅读官方 [DISCLAIMER](https://github.com/index-tts/index-tts)。
- 仅官方渠道：<https://github.com/index-tts/index-tts>，谨防假冒网站。

---

## 免责声明

- **合法用途限制**：本整合包内置的 AI 语音合成 / 声音克隆能力仅供合法的个人学习、研究与正当创作使用。**严禁**将合成声音用于任何欺诈行为（如冒充身份、电信诈骗、伪造语音证据）、传播虚假信息、诽谤侮辱他人、规避安全验证，或任何违反所在国家/地区法律法规的行为。
- **声音与肖像权利**：克隆、模仿特定个人（包括公众人物）的声音前，必须取得该当事人或其合法代表的**明确书面授权**；使用合成内容时亦不得侵犯他人的名誉权、隐私权、著作权等合法权益。
- **监管合规**：不同国家/地区对 AI 生成内容、个人信息保护与声音权益有不同监管要求（如生成内容标识、深度合成备案等），使用者有责任自行了解并遵守适用法律。
- **非官方关系**：本整合包为社区维护的第三方打包，**非 IndexTTS / B 站官方发布**，与官方无任何隶属、赞助或背书关系；官方技术支持请前往官方仓库 <https://github.com/index-tts/index-tts>。
- **责任免除**：作者与贡献者不对因安装、使用或滥用本整合包（包括但不限于模型下载、安装脚本执行、推理输出）造成的任何直接或间接损失、法律后果承担责任。**使用者须对其使用行为负全部责任**。
- **内容审核**：本工具不提供任何形式的生成内容审核或过滤，输出内容可能包含未经校验的错误、偏见或不适当信息，请勿直接用于专业或正式场景。

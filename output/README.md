# output/ — 音频输出目录（已预建）

命令行推理（`start-cli.ps1` / `start-cli.sh`）未指定 `-Output` / `--output` 参数时，生成的音频会默认保存到这里，文件名形如 `gen_20260818_153000.wav`。

## 说明

- 目录已随整合包**预建**，运行 CLI 时会自动写入，无需手动创建。
- 想自己指定位置时，用 `start-cli.ps1 -Output D:\xx\out.wav` 或 `start-cli.sh --output ./out.wav`。
- 内容可随时清空或删除。

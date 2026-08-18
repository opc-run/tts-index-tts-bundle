#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打包 tts-index-tts-bundle skill 为市场发布用 zip。

用法（在整合包根目录下）：
    python tools/package-skill.py          # 生成 skills/dist/tts-index-tts-bundle.zip

流程：
1. 收集 skill 文档：skills/tts-index-tts-bundle/ 下所有文件（SKILL.md、references/*）。
2. 从整合包根目录实时汇入外壳脚本到 zip 的 assets/bundle/ 路径
   （install.* / start-*.* / stop-webui.* / fix-pagefile.bat / README.md / LICENSE），
   避免在 skill 源目录里重复存放一份。
3. 校验 frontmatter 的 name/description、zip 必需条目、无本机绝对路径泄漏。

外壳脚本源文件只保存在整合包根目录；改动根目录脚本后重跑本脚本即可同步进 zip。
"""
import io
import os
import re
import sys
import zipfile

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

# 项目根目录 = 本脚本的上一级（tools/package-skill.py -> 根目录）
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_NAME = "tts-index-tts-bundle"
SRC = os.path.join(ROOT, "skills", SKILL_NAME)
OUT = os.path.join(ROOT, "skills", "dist", f"{SKILL_NAME}.zip")

# 从整合包根目录汇入 zip assets/bundle/ 的外壳文件清单
BUNDLE_FILES = [
    "install.ps1", "install.bat", "install.sh",
    "start-cli.ps1", "start-cli.bat", "start-cli.sh",
    "start-webui.ps1", "start-webui.bat", "start-webui.sh",
    "stop-webui.ps1", "stop-webui.bat",
    "fix-pagefile.bat",
    "README.md", "LICENSE",
]


def fail(msg: str) -> None:
    print(f"ERROR: {msg}")
    sys.exit(1)


def main() -> None:
    if not os.path.isdir(SRC):
        fail(f"skill 源目录不存在: {SRC}")

    # 1. 校验 frontmatter
    skill_md = os.path.join(SRC, "SKILL.md")
    if not os.path.isfile(skill_md):
        fail("SKILL.md 不存在")
    text = open(skill_md, encoding="utf-8").read()
    m = re.search(r"^name:\s*(.+)$", text, re.M)
    name = m.group(1).strip() if m else ""
    print(f"frontmatter name = {name}")
    if name != SKILL_NAME:
        fail(f"expected name '{SKILL_NAME}', got '{name}'")
    if not re.search(r"^description:\s*.+$", text, re.M):
        fail("SKILL.md missing frontmatter description")

    # 2. 打包
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        # 2a. skill 文档
        for dirpath, dirnames, filenames in os.walk(SRC):
            dirnames.sort()
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, SRC).replace("\\", "/")
                z.write(full, rel)
        # 2b. 根目录外壳脚本 -> assets/bundle/
        for fn in BUNDLE_FILES:
            full = os.path.join(ROOT, fn)
            if not os.path.isfile(full):
                fail(f"missing root file: {fn}（外壳脚本源文件在整合包根目录，勿删除）")
            z.write(full, f"assets/bundle/{fn}")
    print(f"packed -> {OUT}")

    # 3. 验证
    with zipfile.ZipFile(OUT) as z:
        names = sorted(z.namelist())
        print(f"zip entries ({len(names)}):")
        for n in names:
            print("  ", n)
        required = ["SKILL.md", "references/usage-and-faq.md"] + \
                   [f"assets/bundle/{f}" for f in BUNDLE_FILES]
        missing = [r for r in required if r not in names]
        if missing:
            fail("zip missing: " + ", ".join(missing))
        for n in names:
            data = z.read(n).decode("utf-8", errors="replace")
            if "e:\\Code" in data or "e:/Code" in data or "\\Code\\" in data:
                fail(f"local path leak in {n}")
    print("OK: all required entries present, no local path leak")


if __name__ == "__main__":
    main()

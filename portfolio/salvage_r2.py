#!/usr/bin/env python3
"""从 B 岛 r2 的 combined artifact 物化一个可 resume 的 run 目录（切回模块文件）。
用法: python portfolio/salvage_r2.py <src_run_dir> <attempt_no> <new_run_name>
"""
import json, re, shutil, sys
from pathlib import Path

src_run, attempt, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
src = Path(src_run)
dst = Path("runs/agent") / new_name
if dst.exists():
    sys.exit(f"dst exists: {dst}")

combined = (src / "artifacts" / f"generated_attempt{attempt}.sv").read_text(encoding="utf-8")
# 按 module 边界切分
chunks = re.findall(r"(^module\s+\w+.*?^endmodule)", combined, re.DOTALL | re.MULTILINE)
if not chunks:
    sys.exit("no modules found")
dst.mkdir(parents=True)
(dst / "project" / "rtl").mkdir(parents=True)
for ch in chunks:
    name = re.search(r"module\s+(\w+)", ch).group(1)
    (dst / "project" / "rtl" / f"{name}.sv").write_text(ch, encoding="utf-8")
# 复用 B 岛 run 的 artifacts（spec/plan 等 resume 依赖）
shutil.copytree(src / "artifacts", dst / "artifacts", dirs_exist_ok=True)
for extra in ("graph.json", "events.json", "handoffs", "checkpoints"):
    sp = src / extra
    if sp.exists():
        if sp.is_dir():
            shutil.copytree(sp, dst / extra, dirs_exist_ok=True)
        else:
            shutil.copy2(sp, dst / extra)
print(f"materialized {dst} with {len(chunks)} modules")

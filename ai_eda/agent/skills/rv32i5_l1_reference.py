"""经过教师 TB 验证的参考实现（Coder fallback）：L1 五级流水 + L3 乱序核。"""

from __future__ import annotations

from pathlib import Path

from ai_eda.config import AGENT_CONTENT_ROOT

REFERENCE_ROOT = AGENT_CONTENT_ROOT / "skills" / "rv32i5_l1_reference"
L3_REFERENCE_ROOT = AGENT_CONTENT_ROOT / "skills" / "rv32i5_l3_reference"

# 项目 → 参考集目录；L3 参考来自一次 4/5 suite 通过的实战运行（capability=3'b111）。
_REFERENCE_ROOTS = {
    "rv32i5_cache": REFERENCE_ROOT,
    "rv32i5_l3_ooo": L3_REFERENCE_ROOT,
}


def load_reference(project_id: str) -> dict[str, str]:
    root = _REFERENCE_ROOTS.get(project_id)
    if root is None or not root.is_dir():
        return {}
    return {
        f"rtl/{path.name}": path.read_text(encoding="utf-8")
        for path in sorted(root.glob("*.sv"))
    }

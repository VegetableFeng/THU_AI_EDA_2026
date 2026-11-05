"""Agent 任务项目注册表：每个项目有独立的 Spec / TB / Tester 配置。"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ai_eda.config import TASKS_ROOT

DEFAULT_PROJECT_ID = "stream_filter"

_PROJECTS: dict[str, dict[str, Any]] = {
    "stream_filter": {
        "id": "stream_filter",
        "title": "Synchronous Byte-Stream FIFO",
        "description": "DSE-enabled synchronous FIFO with 16-byte bursts and a 16-bit checksum; the Planner Skill selects depth, storage, and pointer architecture for lower area and power.",
        "spec_path": TASKS_ROOT / "stream_filter" / "spec.md",
        "testbench_path": TASKS_ROOT / "stream_filter" / "tb.sv",
        "testbench_top": "tb_agent_stream_filter",
        "power_testbench_path": TASKS_ROOT / "stream_filter" / "power_tb.sv",
        "power_testbench_top": "tb_power_agent_stream_filter",
        "task_name": "agent_stream_filter",
    },
    "rv32i5": {
        "id": "rv32i5",
        "title": "RV32I · L0 Five-Stage Pipeline",
        "description": "Baseline RV32I five-stage pipeline: forwarding, load-use stalls, and branch flush; shares the teacher TB and performance benchmarks with the advanced tiers.",
        "spec_path": TASKS_ROOT / "homework_rv32i5" / "specs" / "spec.md",
        "timeout_seconds": 60,
        "testbench_path": TASKS_ROOT / "homework_rv32i5" / "tb.sv",
        "testbench_top": "tb_agent_rv32i5",
        "power_testbench_path": TASKS_ROOT / "homework_rv32i5" / "power_tb.sv",
        "power_testbench_top": "tb_power_agent_rv32i5",
        "task_name": "agent_rv32i5",
        "expected_cpu_level": 0,
    },
}

# 四个项目只选择不同的设计要求；教师测试入口及性能口径保持一致。
for _project_id, _level, _title, _description, _spec_file in (
    (
        "rv32i5_cache", 1, "RV32I · L1 I/D Cache",
        "Five-stage pipeline with separate I/D caches: cache hits, conflict replacement, byte writes, and miss stalls.", "spec_l1_cache.md",
    ),
    (
        "rv32i5_predict", 2, "RV32I · L2 Cache + Predictor",
        "I/D caches with dynamic branch prediction: BTB/BHT, training, misprediction recovery, and wrong-path side-effect isolation.", "spec_l2_predict.md",
    ),
    (
        "rv32i5_ooo", 3, "RV32I · L3 OoO",
        "Caches, branch prediction, register renaming, out-of-order execution, and in-order ROB commit.", "spec_l3_ooo.md",
    ),
):
    _PROJECTS[_project_id] = {
        **_PROJECTS["rv32i5"],
        "id": _project_id,
        "title": _title,
        "description": _description,
        "spec_path": TASKS_ROOT / "homework_rv32i5" / "specs" / _spec_file,
        "expected_cpu_level": _level,
    }
# L3 乱序核仿真更慢（离线实测全量 TB ~250s+），60s 模板超时会把健康设计
# 误杀为 simulation_timeout；按层级放宽。
_PROJECTS[_project_id]["timeout_seconds"] = 60 + 80 * _level
# PPA 预算（仅在 metrics 可用时检查）：L3 基线 350.9k µm² / 76.3 mW，
# 预算迫使 agent 做等价重构优化（ckpt 减半、cache 行数、写使能门控）。
if _level == 3:
    _PROJECTS[_project_id]["area_budget_um2"] = 300000
    _PROJECTS[_project_id]["power_budget_w"] = 0.060


def get_project(project_id: str | None = None) -> dict[str, Any]:
    """返回一个项目配置；未知项目回退到默认项目。"""
    key = project_id or DEFAULT_PROJECT_ID
    project = _PROJECTS.get(key)
    if project is None:
        raise ValueError(f"未知 Agent 项目：{project_id}")
    return dict(project)


def list_projects() -> list[dict[str, Any]]:
    """返回给前端展示的项目元数据，不暴露内部路径。"""
    return [project_public(item) for item in _PROJECTS.values()]


def project_public(project: dict[str, Any]) -> dict[str, Any]:
    public = {
        "id": project["id"],
        "title": project["title"],
        "description": project["description"],
    }
    if "expected_cpu_level" in project:
        public["expected_cpu_level"] = project["expected_cpu_level"]
        public["cpu_level_label"] = {
            0: "L0 · 基础流水线",
            1: "L1 · I/D Cache",
            2: "L2 · Cache + 分支预测",
            3: "L3 · Cache + 预测 + 乱序",
        }[project["expected_cpu_level"]]
    return public


def project_spec(project_id: str | None = None) -> str:
    project = get_project(project_id)
    return Path(project["spec_path"]).read_text(encoding="utf-8")

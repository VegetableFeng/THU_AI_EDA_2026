"""Coder 子 Agent：按计划逐文件生成 RTL。"""

from __future__ import annotations

import json
from pathlib import Path

from ai_eda.model.client import RTL_SYSTEM_PROMPT
from ai_eda.rtl.runner import extract_rtl
from ai_eda.agent.skills.rv32i5_l1_reference import load_reference

from .base import SubAgent
from .common import (
    CODER_SELF_CHECK,
    CODER_SELF_CHECK_RV32I,
    RV32I_ADVANCED_TIMING,
    RV32I_L1_CODE_PATTERNS,
    RV32I_PIPELINE_CHECKLIST,
    RV32I_TIMING_CONSTRAINTS,
    safe_project_path,
)


def _architecture_block(plan: dict) -> str:
    architecture = plan.get("architecture")
    if not isinstance(architecture, dict):
        return ""
    parameters = architecture.get("parameters") or {}
    directives = architecture.get("coder_directives") or []
    reference = architecture.get("reference_structure") or {}
    return (
        "\n\nPlanner Skill 预评估架构参数（直接来自 Python Skill，必须严格遵守）：\n"
        + json.dumps(parameters, ensure_ascii=False, indent=2)
        + "\n\nCoder 指令：\n"
        + "\n".join(f"- {item}" for item in directives)
        + "\n\n参考结构：\n"
        + json.dumps(reference, ensure_ascii=False, indent=2)
        + "\n"
    )


class CoderAgent(SubAgent):
    name = "coder"
    title = "03 · Coder"
    node_type = "coder"
    # RTL 生成同样属于工具型输出。L1/L2 的 Plan+Spec 很长，思考模式可能把
    # 60k 输出预算全部消耗在 reasoning 上，导致没有 RTL 文本。默认关闭思考，
    # 把预算留给完整的 SystemVerilog 文件。
    MODEL_OPTIONS = {"thinking": False}

    def run(
        self,
        planner_handoff: Path,
        *,
        existing_files: dict[str, str] | None = None,
        start_module: str | None = None,
    ) -> Path:
        incoming = self.runtime.read_handoff(planner_handoff)["payload"]
        artifacts = incoming.get("artifacts") or {}
        spec_ref = artifacts.get("spec")
        plan_ref = artifacts.get("plan")
        if not isinstance(spec_ref, str) or not isinstance(plan_ref, str):
            raise ValueError("Planner → Coder handoff 缺少 Spec 或 Plan artifact")
        effective_spec = self.runtime.read_text_artifact(spec_ref)
        plan = self.runtime.read_json_artifact(plan_ref)
        if not isinstance(plan, dict):
            raise ValueError("Plan artifact 格式无效")
        project_id = str((self.runtime.options.get("project") or {}).get("id") or "")
        project_checklist = (
            "\n\n" + RV32I_PIPELINE_CHECKLIST + "\n\n" + RV32I_L1_CODE_PATTERNS
            if project_id.startswith("rv32i5")
            else ""
        )
        files: dict[str, str] = {}
        existing = existing_files or {}
        reference = load_reference(str(project_id))
        # 参考实现存在时：一次性写入全部参考文件（包括 plan 未列出的辅助模块，
        # 如 rv32i5_l1 的 alu），保证参考集内部接口自洽；plan 中对应模块直接跳过。
        # 参考文件优先于上一等级的复用文件，避免两套实现的端口约定混搭。
        if reference:
            for path, content in sorted(reference.items()):
                target = safe_project_path(self.runtime.run_dir, path)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content, encoding="utf-8")
                files[path] = content
            event = self.runtime.begin_event(
                "coder",
                self.node_type,
                f"{self.title} · reference files",
                f"Write {len(reference)} reference files (course-verified fallback).",
            )
            self.finish(
                event,
                "info",
                response=f"Wrote {len(reference)} reference files: " + "、".join(sorted(reference)),
            )
        modules = plan["modules"]
        start_index = 0
        if start_module:
            for index, module in enumerate(modules):
                if module.get("name") == start_module:
                    start_index = index
                    break
        architecture_block = _architecture_block(plan)
        for index, module in enumerate(modules):
            if index < start_index and module["file"] in existing:
                files[module["file"]] = existing[module["file"]]
                continue
            if module["file"] in reference:
                # 参考文件已随参考集统一写入，直接沿用。
                continue
            if module.get("reuse") and module["file"] in existing:
                # 进化模式：Planner 标记复用的模块直接沿用上一等级的实现。
                files[module["file"]] = existing[module["file"]]
                event = self.runtime.begin_event(
                    "coder",
                    self.node_type,
                    f"{self.title} · {module['name']} (reuse)",
                    "Reuse existing implementation from the previous level.",
                )
                self.finish(
                    event,
                    "info",
                    response=f"Reused {module['file']} from previous level ({len(existing[module['file']])} chars).",
                )
                continue
            if project_id.startswith("rv32i5"):
                timing_block = RV32I_TIMING_CONSTRAINTS
                if project_id in {"rv32i5_l2_predict", "rv32i5_l3_ooo"}:
                    timing_block += "\n" + RV32I_ADVANCED_TIMING
                self_check = CODER_SELF_CHECK + "\n" + CODER_SELF_CHECK_RV32I
            else:
                timing_block = (
                    "1. valid/ready 握手：请求发出后 valid 与载荷必须保持到 ready，未 ready 时不得变更请求。\n"
                    "2. 复位为同步低有效，复位后各输出符合 Spec 的初始状态。"
                )
                self_check = CODER_SELF_CHECK
            prompt = (
                f"请实现项目中模块 `{module['name']}`，写入文件 `{module['file']}`。"
                "只输出该文件的完整 SystemVerilog RTL：不要输出 Markdown 围栏、解释文字或额外模块。\n\n"
                "一、接口约束（必须逐字符遵守）\n"
                "模块端口与跨模块信号以计划 interfaces 为准：名称/方向/位宽不得改名或增删；"
                "端口列表已声明的信号不得在模块体内重复声明；每个信号只能有一个 driver。\n\n"
                "二、微架构与实现要点\n"
                + architecture_block
                + project_checklist
                + "\n三、时序约束（教师 TB 逐项检查，违反任何一条都会失败）\n"
                + timing_block
                + "\n\n四、可综合性约束\n"
                "时序逻辑用 always_ff @(posedge clk)；组合逻辑用 always_comb 且全分支赋值无锁存器；"
                "function 内禁止 SystemVerilog return（用函数名赋值）；不使用 typedef enum、"
                "class、interface、断言、动态数组；复位为同步低有效，禁止 negedge rst_n 写法。\n\n"
                "五、项目计划与 Spec\n"
                f"本模块说明：{module['description']}\n本模块接口契约：{module['interfaces']}\n"
                f"{json.dumps(plan, ensure_ascii=False, indent=2)}\n\n"
                f"Spec：\n{effective_spec}\n\n"
                "六、生成后自查（逐条确认全部通过后再输出）\n"
                + self_check
            )
            event = self.runtime.begin_event(
                "coder", self.node_type, f"{self.title} · {module['name']}", prompt
            )
            result = self.runtime.call_model(
                event, prompt, RTL_SYSTEM_PROMPT, model_options=self.MODEL_OPTIONS
            )
            rtl = extract_rtl(result.get("answer") or "")
            if not rtl.strip() or "module" not in rtl:
                raise ValueError(f"Coder 没有为 {module['name']} 生成有效 RTL")
            target = safe_project_path(self.runtime.run_dir, module["file"])
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(rtl, encoding="utf-8")
            files[module["file"]] = rtl
            artifact_dir = self.runtime.run_dir / f"step-{event['step']:02d}-{event['node_id']}"
            (artifact_dir / "generated.sv").write_text(rtl, encoding="utf-8")
            self.save_context(plan_ref=plan_ref, last_file=self.runtime.artifact_ref(target))
            self.finish(
                event,
                "info",
                response=f"Wrote {module['file']} ({len(rtl)} chars).",
                rtl=rtl,
                reasoning=event.get("reasoning"),
                usage=event.get("usage"),
            )
        manifest = {
            "files": [
                {
                    "path": path,
                    "artifact": self.runtime.artifact_ref(
                        safe_project_path(self.runtime.run_dir, path)
                    ),
                    "bytes": len(content.encode("utf-8")),
                }
                for path, content in files.items()
            ]
        }
        manifest_ref = self.runtime.write_json_artifact("rtl_manifest.json", manifest)
        self.save_context(plan_ref=plan_ref, rtl_manifest_ref=manifest_ref)
        return self.runtime.write_handoff(
            "coder",
            "tester",
            {
                "artifacts": {
                    "spec": spec_ref,
                    "plan": plan_ref,
                    "rtl_manifest": manifest_ref,
                },
            },
            label="Coder → Tester: RTL manifest",
        )

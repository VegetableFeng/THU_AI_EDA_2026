"""RTL Planner 子 Agent：规划模块与文件结构。"""

from __future__ import annotations

import json
from pathlib import Path

from ai_eda.agent.skills.fifo_area_power import evaluate as evaluate_fifo_skill

from .base import SubAgent
from .common import PLANNER_SYSTEM_PROMPT, extract_json_payload, validate_plan


class PlannerAgent(SubAgent):
    name = "planner"
    title = "02 · RTL Planner"
    node_type = "planner"

    def run(self, parser_handoff: Path) -> Path:
        incoming = self.runtime.read_handoff(parser_handoff)["payload"]
        artifacts = incoming.get("artifacts") or {}
        spec_ref = artifacts.get("spec")
        if not isinstance(spec_ref, str):
            raise ValueError("Parser → Planner handoff 缺少 spec artifact")
        effective_spec = self.runtime.read_text_artifact(spec_ref)
        skill_result: dict | None = None
        skill_ref: str | None = None
        skill_prompt = ""
        project_id = (self.runtime.options.get("project") or {}).get("id")
        if self.runtime.options.get("planner_skill") and project_id == "stream_filter":
            skill_result = evaluate_fifo_skill(effective_spec)
            skill_ref = self.runtime.write_json_artifact("planner_skill.json", skill_result)
            skill_prompt = (
                "\n\nPlanner Skill 已运行，下面是面积/功耗预评估与架构参数。"
                "必须把 architecture 字段原样写入计划，并要求所有 Coder 严格遵守其中的 coder_directives：\n"
                f"{json.dumps(skill_result, ensure_ascii=False, indent=2)}\n"
            )
        evolution = self.runtime.options.get("evolution")
        evolution_prompt = ""
        if isinstance(evolution, dict) and evolution.get("inventory"):
            old_plan = evolution.get("old_plan")
            evolution_prompt = (
                "\n\n本次运行为跨等级进化：项目已包含上一等级通过教师 TB 验收的实现文件，清单如下：\n"
                + json.dumps(evolution.get("inventory"), ensure_ascii=False, indent=2)
                + "\n请尽量复用已满足新 Spec 的模块：对应 module 置 \"reuse\": true 并保持 file 与接口不变；"
                "只为新增能力或必须重写的模块规划新文件（reuse 置 false 或缺省）。"
                "最终计划必须包含整个项目的全部模块（复用 + 新增），新模块与复用模块的接口必须一致。\n"
                + (
                    "上一等级的计划（可继承接口定义）：\n"
                    + json.dumps(old_plan, ensure_ascii=False, indent=2)
                    + "\n"
                    if isinstance(old_plan, dict)
                    else ""
                )
            )
        prompt = (
            "根据下面的 Spec 规划 RTL 项目的模块与文件结构。每个模块必须能由一个文件独立实现；"
            "所有模块最终会一起用教师 TB 编译验收。每个 module 的 interfaces 必须写全端口名、方向、位宽；"
            "跨模块信号在两端必须使用同名、同方向、同宽度，不能只写一句总结。\n"
            "时序职责分配：把复位、冒险与停顿（load-use/结构冒险）、冲刷、ECALL 停机提交、"
            "握手等待等时序逻辑显式分配到明确的模块（如 hazard_unit、wb_stage），"
            "并在该模块的 description 中写明它承担哪些时序职责，避免多个模块各写一套互相打架。\n"
            + evolution_prompt
            + skill_prompt
            + f"\nSpec：\n{effective_spec}\n\n"
            "请只返回约定的 JSON 对象。"
        )
        event = self.runtime.begin_event("planner", self.node_type, self.title, prompt)
        result = self.runtime.call_model(event, prompt, PLANNER_SYSTEM_PROMPT)
        try:
            plan = validate_plan(extract_json_payload(result.get("answer") or ""))
        except ValueError as error:
            raise ValueError(f"Planner 规划无效：{error}") from error
        if skill_result is not None:
            plan["architecture"] = skill_result
        plan_ref = self.runtime.write_json_artifact("plan.json", plan)
        self.save_context(
            spec_ref=spec_ref,
            plan_ref=plan_ref,
            planner_skill_ref=skill_ref,
        )
        self.finish(
            event,
            "info",
            response=json.dumps(plan, ensure_ascii=False, indent=2),
            reasoning=event.get("reasoning"),
            usage=event.get("usage"),
        )
        return self.runtime.write_handoff(
            "planner",
            "coder",
            {
                "artifacts": {
                    "spec": spec_ref,
                    "plan": plan_ref,
                    **({"skill": skill_ref} if skill_ref else {}),
                }
            },
            label="Planner → Coder: Spec / Plan artifacts",
        )

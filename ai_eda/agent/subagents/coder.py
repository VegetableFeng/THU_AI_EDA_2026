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
    RV32I_L3_BUG_PATTERNS,
    RV32I_PIPELINE_CHECKLIST,
    RV32I_TIMING_CONSTRAINTS,
    extract_json_payload,
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
        evolution = self.runtime.options.get("evolution")
        evolution_discipline = ""
        if isinstance(evolution, dict):
            evolution_discipline = (
                "\n进化纪律（本项目由已通过教师 TB 验证的上一等级实现进化而来）：\n"
                "1. 标记 reuse 的模块沿用已验证实现，其内部逻辑不得重写或复制改动。\n"
                "2. ECALL→halt→retire 停机时序路径（含 dbg_retire_valid 单拍脉冲、"
                "halted/exit_code 提交拍数、停顿期间 ECALL 保持）已被验证：新增逻辑"
                "（如预测器）只能通过既有的重定向/PC 选择点接入，不得复制或重写该路径。\n"
                "3. 新增模块与既有模块对接时，信号名称/位宽以计划 interfaces 为准，"
                "且不得改变既有模块的端口。\n"
            )
        for index, module in enumerate(modules):
            # 进化模式的 extend 档：模块在上一等级已存在但未被标记 reuse——
            # 必须以上一等级已验证的实现为基线做最小扩展，禁止从零重写。
            extend_base = None
            if (
                isinstance(evolution, dict)
                and not module.get("reuse")
                and module["file"] in existing
                and module["file"] not in reference
            ):
                extend_base = existing[module["file"]]
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
                if project_id == "rv32i5_l3_ooo":
                    timing_block += "\n" + RV32I_OOO_PATTERNS
                    timing_block += "\n" + RV32I_L3_BUG_PATTERNS
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
            )
            if extend_base is not None:
                prompt += (
                    "零、进化基线（最高优先级）\n"
                    "下面是本模块在上一等级已通过教师 TB 验证的完整实现。你的任务是在它基础上"
                    "做**最小扩展**以实现计划新增的职责，而不是从零重写：\n"
                    "1. 已验证行为（复位值、握手、取指/停机时序、前递、流水线 valid 管理）必须逐行保留；\n"
                    "2. 端口权威顺序：基线文件的**既有端口（名称/方向/位宽）高于计划 interfaces**——"
                    "计划中与之冲突的端口条目一律以基线为准，顶层与对接模块也必须按基线端口连接；"
                    "只允许**追加**新能力所需的新端口；\n"
                    "3. 新逻辑接入点必须复用既有选择器/优先级结构（如 PC 更新的重定向优先级），不得另起平行路径；\n"
                    "4. 输出的完整文件 = 基线内容 + 最小增量。若你的输出与基线差异超过新能力所需，即为错误。\n\n"
                    "基线文件内容：\n```systemverilog\n" + extend_base + "\n```\n\n"
                )
            prompt += (
                "一、接口约束\n"
                + (
                    "既有端口以进化基线为准（名称/方向/位宽不得改变，计划 interfaces 中冲突条目以基线覆盖）；"
                    "新增端口以计划 interfaces 为准。"
                    if extend_base is not None
                    else "模块端口与跨模块信号以计划 interfaces 为准：名称/方向/位宽不得改名或增删；"
                )
                + "端口列表已声明的信号不得在模块体内重复声明；每个信号只能有一个 driver。\n\n"
                "二、微架构与实现要点\n"
                + architecture_block
                + project_checklist
                + evolution_discipline
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
            if extend_base is not None:
                # 补丁式扩展：模型只输出锚点补丁（expected/replacement），
                # 由本地原子应用到基线——从机制上禁止重写基线未提及的行为。
                patch_prompt = prompt + (
                    "\n七、输出协议（本模块为补丁式扩展，必须遵守）\n"
                    "不要输出完整文件。只输出一个 JSON 对象：\n"
                    '{"edits": [{"path": "'
                    + module["file"]
                    + '", "expected": "<基线中逐字唯一的一段原文>", '
                    '"replacement": "<替换后的完整段落>"}], "notes": "..."}\n'
                    "规则：每个 edit 的 expected 必须逐字来自基线文件且全文唯一；"
                    "replacement 中未被修改的行必须与基线逐字一致；"
                    "新增逻辑写成独立 edit，不要把整个模块重写为一个 edit；"
                    "总新增行数不得超过 300 行。禁止输出 Markdown 围栏或解释。\n"
                )
                result = self.runtime.call_model(
                    event, patch_prompt, RTL_SYSTEM_PROMPT, model_options=self.MODEL_OPTIONS
                )
                from ai_eda.agent.patches import apply_repair_payload

                baseline_map = {module["file"]: extend_base}
                rtl: str | None = None
                last_patch_error: ValueError | None = None
                anchor_feedback = ""
                artifact_dir_pre = self.runtime.run_dir / f"step-{event['step']:02d}-{event['node_id']}"
                artifact_dir_pre.mkdir(parents=True, exist_ok=True)
                # 协议降级阶梯：3 轮补丁协议（模型输出小、守卫强）失败后，
                # 第 4 轮回退到完整文件协议（模型更擅长），端口/行数守卫继续兜底。
                for patch_attempt in range(1, 5):
                    if patch_attempt > 1:
                        if patch_attempt < 4:
                            retry_prompt = (
                                f"上一次补丁无效（{last_patch_error}）。请基于同一基线重新给出 edits 数组，"
                                "expected 必须逐字唯一地来自基线文件，replacement 保留未修改行。"
                                "只输出 JSON 对象。"
                                + anchor_feedback
                            )
                        else:
                            retry_prompt = (
                                "补丁协议连续失败，最后一次改用完整文件协议：\n"
                                "直接输出该模块扩展后的**完整 SystemVerilog 文件内容**（基线 + 新增逻辑），"
                                "不要 JSON、不要 Markdown 围栏、不要解释。"
                                "既有端口（名称/方向/位宽）必须逐字保留，只允许追加新端口与新逻辑；"
                                "新增行数不得超过 400 行。\n"
                                f"基线文件内容：\n```systemverilog\n{extend_base}\n```\n"
                                + anchor_feedback
                            )
                        result = self.runtime.call_model(
                            event, retry_prompt, RTL_SYSTEM_PROMPT, model_options=self.MODEL_OPTIONS
                        )
                    answer_now = result.get("answer") or ""
                    (artifact_dir_pre / f"patch_attempt{patch_attempt}_response.txt").write_text(
                        answer_now, encoding="utf-8"
                    )
                    try:
                        if patch_attempt == 4:
                            rtl = extract_rtl(answer_now)
                            if not rtl.strip() or "module" not in rtl:
                                raise ValueError("完整文件协议输出中没有有效 RTL")
                        else:
                            payload = extract_json_payload(answer_now)
                            if isinstance(payload, dict) and payload.get("no_change") is True:
                                # 模型声明本模块无需修改：沿用基线（等价 reuse）。
                                rtl = extend_base
                                self.save_context(last_no_change=module["file"])
                                break
                            application = apply_repair_payload(payload, baseline_map)
                            changed = application.changed_files
                            if not changed:
                                raise ValueError("补丁没有产生任何修改")
                            rtl = changed[module["file"]]
                        # 变体守卫：基线中未出现的结构性改动（如 module 端口行被改写）即拒绝。
                        base_ports = [l for l in extend_base.splitlines() if l.strip().startswith(("module ", "    input", "    output"))]
                        new_ports = [l for l in rtl.splitlines() if l.strip().startswith(("module ", "    input", "    output"))]
                        removed = [l for l in base_ports if l not in new_ports]
                        if removed:
                            raise ValueError(
                                "补丁删除或改写了既有端口行（必须只增不改）：" + "；".join(removed[:3])
                            )
                        added_lines = sum(1 for l in rtl.splitlines() if l not in extend_base.splitlines())
                        if added_lines > 400:
                            raise ValueError(f"补丁新增 {added_lines} 行，超出最小扩展限制（400 行）")
                        break
                    except ValueError as error:
                        # 锚点未命中时给模型基线对照：自动找最相似的行块（带行号），
                        # 模型下一次重试即可用逐字正确的锚点，而不是继续凭记忆猜测。
                        message = str(error)
                        if "anchor was not found" in message or "anchor is ambiguous" in message:
                            import difflib

                            snippets: list[str] = []
                            try:
                                for bad_edit in (payload or {}).get("edits", []):
                                    exp = bad_edit.get("expected")
                                    if not isinstance(exp, str) or not exp.strip():
                                        continue
                                    e_lines = exp.splitlines()
                                    b_lines = extend_base.splitlines()
                                    n = len(e_lines)
                                    if n == 0 or len(b_lines) < 1:
                                        continue
                                    best_ratio, best_start = 0.0, 0
                                    for start in range(0, max(1, len(b_lines) - n + 1)):
                                        window = b_lines[start : start + n]
                                        ratio = sum(
                                            difflib.SequenceMatcher(None, a, b).ratio()
                                            for a, b in zip(e_lines, window)
                                        ) / n
                                        if ratio > best_ratio:
                                            best_ratio, best_start = ratio, start
                                    snippet = "\n".join(
                                        f"{best_start + i + 1:5d}| {line}"
                                        for i, line in enumerate(b_lines[best_start : best_start + n])
                                    )
                                    snippets.append(
                                        f"expected 开头 {exp.strip().splitlines()[0][:60]!r} "
                                        f"→ 基线中最相似片段（相似度 {best_ratio:.0%}）：\n{snippet}"
                                    )
                            except Exception:
                                pass
                            if snippets:
                                anchor_feedback = (
                                    "\n\n基线对照（你的 expected 与基线不一致；"
                                    "请从下面这些逐字片段中复制锚点，或修正方向/拼写后再输出）：\n"
                                    + "\n\n".join(snippets)
                                )
                        last_patch_error = ValueError(
                            f"attempt {patch_attempt}: {error} | answer[:160]={answer_now[:160]!r}"
                        )
                        rtl = None
                if rtl is None or "module" not in rtl:
                    raise ValueError(f"Coder 补丁式扩展失败：{last_patch_error}")
            else:
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

"""Parser / Planner / Coder / Tester / Diagnoser / Patch 共用的协议与工具函数。"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from ai_eda.agent.reporting import report_summary, stage_label

PARSER_SYSTEM_PROMPT = """You are the Spec Parser of a digital IC design agent.
Decide whether the given design spec (plus user supplements and previous parser addendum) is sufficient to implement, plan, and verify the design.
Your job is to SUPPLEMENT and CORRECT the original spec, never to summarize or replace it.

Blocking gaps (ask the user):
- missing/contradictory top-level ports, clock/reset, ISA behavior, external bus handshake, ECALL/halt behavior, file/task structure, or externally observable test expectations;
- requirements that make a correct implementation impossible or make PASS depend on an undefined architectural choice.

Non-blocking details (do NOT ask; record short assumptions in spec_addendum instead):
- internal module port names, internal handshake/FSM/state encoding details;
- Cache refill arbitration, epoch bit-width/implementation, internal buffers/queues, predictor table encoding;
- ROB/rename/issue implementation details not externally observable;
- optional auxiliary file names or internal RAM implementation choices.
These belong to Planner/Coder/Modifier and may be frozen later; do not block the flow on them.

When only non-blocking gaps remain, set sufficient=true, missing=[], questions=[], and put concise assumptions in spec_addendum.
Keep every original requirement intact. Return ONLY a JSON object:
{"sufficient": true|false, "missing": ["..."], "questions": ["..."], "spec_addendum": "only additional/corrected requirements or assumptions in Markdown; empty if none"}
Do not put the full original spec in spec_addendum. Do not return Markdown fences or extra text."""

PLANNER_SYSTEM_PROMPT = """You are the RTL Planner of a digital IC design agent.
Given the frozen spec, plan the project module and file structure. The agent will write each file separately.
Return ONLY a JSON object:
{"project_name": "...", "top_module": "...", "modules": [{"name": "module_name", "file": "rtl/module_name.sv", "description": "short responsibility", "interfaces": "complete port contract: every port name, direction and width; for each inter-module signal use the same name/width in all modules"}], "notes": "..."}
Use only relative paths ending in .sv. Every module must be implementable in one file. The interfaces field is the interface contract: list every port name, direction and width, and use identical names/widths for a signal in every module. Do not return Markdown fences or extra text."""

RV32I_L1_CODE_PATTERNS = """RV32I L1 tactical patterns (use these structures; keep interfaces from the plan):
1) IF response / stall:
  always_ff @(posedge clk) begin
    if (!rst_n) ...
    else if (redirect_valid) ...
    else if (ecall_in_id && !halt_pending && !mem_stall) begin
      halt_pending <= 1'b1; req_pending <= 1'b0; end
    else if (cpu_resp_valid) begin
      if2id_valid<=1; if2id_pc<=pc; if2id_pc4<=pc+4; if2id_insn<=cpu_resp_data;
      pc<=pc+4; req_pending<=1; end
    else if (stall) begin if2id_valid<=if2id_valid; end
    else begin if (req_pending && cpu_req_ready) begin req_pending<=0; if2id_valid<=0; end end
  end
  Never put a stall branch before the one-cycle cpu_resp_valid branch, and never clear if2id_valid on stall.
2) MEM response:
  if (mem_active) begin
    if (cpu_resp_valid) begin mem2wb_valid<=1; ...; mem_active<=0; mem_wait_resp<=0; end
    else if (!mem_wait_resp && cpu_req_ready) mem_wait_resp<=1;
  end
3) DCache word/store:
  assign hit_word = line_data[{wsel,5'b00000} +: 32];
  // store hit: merge only enabled bytes into the selected word, then write back
  // store miss: do not claim a valid line with stale data; either merge the refilled word
  // or invalidate the line and refill on the next load.
4) ICache refill:
  // do not return state to IDLE on flush. Keep mem_req_valid/addr stable until mem_req_ready.
  // On the last word always install valid/tag/data; gate only resp_valid_r/resp_data_r
  // with flush_epoch==refill_epoch. For refill_word==3 use the current mem_resp_data.
5) EX forwarding:
  rs1_fwd = id2ex_rs1_val;
  if (fwd_a==2'b10) rs1_fwd = ex2mem_result;       // EX/MEM ALU result
  else if (fwd_a==2'b01) rs1_fwd = mem2wb_wdata;   // MEM/WB result
  // same for rs2; ex2mem_result for JAL/JALR must be pc4, not the address ALU output.
6) Halt: only WB sees mem2wb_valid && mem2wb_is_ecall and sets halted/exit_code; preserve is_ecall through stall.
"""

RV32I_PIPELINE_CHECKLIST = """RV32I L1/L2 implementation hard checks:
- One-cycle response pulses: if a cache/bus producer asserts resp_valid for one cycle, the consumer must capture resp_valid unconditionally before checking a wait/ready flag; never rely on a wait flag that is set only on the following cycle.
- Stall/freeze: while load_use_stall, mem_stall, or structural stall is active, hold IF/ID valid and ID/EX valid; never clear a valid instruction just because the downstream stage is stalled.
- ECALL/halt: ECALL must stay valid through ID -> EX -> MEM -> WB while stalls are active; only WB may set halted/exit_code. Do not drop an ECALL that is waiting in IF/ID while ID is frozen.
- Cache word lanes: for a 128-bit line, word selection is wsel*32 bits, e.g. line_data[{wsel,5'b00000} +: 32], not wsel*4 bit.
- Store merge: write-through store hit must merge only byte-enable lanes into the line; store miss should either merge the requested word explicitly or invalidate the line (no-write-allocate) so a later load refills correct data.
- Cache line refill: never abort an already-issued external refill before ready; hold valid/address stable until ready, finish all words, then install valid/tag/data (a redirect may suppress only the response, not destroy the line).
- I-Cache refill word3: use the current last memory response for word3, not an old/empty refill register.
- Forwarding: implement BOTH EX/MEM (fwd=2'b10) and MEM/WB (fwd=2'b01) paths; JAL/JALR EX/MEM result must select pc4/pc according to wb_sel, never blindly forward ALU result.
- Halt/reset: synchronous active-low reset, dmem_valid=0 during reset; halted/exit_code are registered and stable after ECALL commits.
"""

RV32I_TIMING_CONSTRAINTS = """1. 复位：同步低有效，只在 clk 上升沿生效；复位期间 dmem_valid=0；PC 更新优先级：复位 > 控制转移重定向 > ECALL 停机冻结 > load-use 暂停 > PC+4。
2. 稳态性能：直线 ALU 程序稳态 CPI=1（每拍退休一条）；load-use 暂停恰好 1 拍（冻结 PC 与 IF/ID、清 ID/EX 的 valid，不冲刷更老指令）；Taken 控制转移最多 2 个 bubble；除 load-use 与重定向冲刷外不得停顿。
3. 停机时序：ECALL 保持有效经 ID→EX→MEM→WB（停顿期间不得丢弃）；WB/提交沿产生一次 dbg_retire_valid 且该沿 halted/exit_code 仍为 0；下一时钟沿 halted=1 且 exit_code=x10；任何周期不得出现 halted=0 且 exit_code!=0；halted=1 后所有输出与架构状态保持稳定。
4. 退休事件：每条真正提交的指令恰好产生一个单拍 dbg_retire_valid（含 load/store/branch/NOP/rd=x0/ECALL）；每拍至多退休一条；停顿不得重复计数，被冲刷或无效项不得产生事件。
5. 前递：EX 级前递 EX/MEM 优先于 MEM/WB；load 结果只经 MEM/WB 前递（load-use 暂停保证）；store data 在 MEM 级前递；分支比较、JALR 的 rs1、store 地址均使用前递后的值；ID 读口与 WB 写口同址时必须读到正在写入的新值。
6. 外部握手：同一接口至多一个在途请求；请求发出后 valid/addr 必须保持到 ready；TB 会插入确定性与变化的等待周期，不得假定 ready 常为 1；运行中每个周期 imem_addr[1:0]=00。"""

RV32I_ADVANCED_TIMING = """7. 分支预测事件（L2/L3）：dbg_bp_resolve 对每条有效控制转移（条件分支/JAL/JALR）在实际解析沿恰好置 1 一个周期，每条至多一个事件；dbg_bp_mispredict 仅当预测下一 PC 与实际不同，与 resolve 同拍；停顿不得重复计数，复位/冲刷后的无效项不计。
8. 乱序事件（L3）：dbg_ooo_issue 为发射队列中有效指令被功能单元真正接受的那拍；dbg_ooo_bypass 标记"存在更老未完成 load 时，更年轻的独立整数 ALU 指令仍被发射并完成"的事件；两者必须来自真实内部状态，禁止用计数器或 PC 模式伪造。
9. Cache 时序（L1-L3）：cache 命中下稳态 CPI≈1；miss 周期不受零等待 L0 的"load-use 恰 1 拍"约束，但 refill 期间请求必须保持、不得 abort 在途事务；store 命中只合并 byte-enable 覆盖的字节，store miss 不得装配陈旧行。"""

CODER_SELF_CHECK = """1. 只输出本模块；端口与计划 interfaces 逐字符一致（名称/方向/位宽）；所有输出端口都被驱动；无重复声明、无多驱动。
2. 复位为同步低有效；本模块全部状态寄存器有确定复位值；复位期间外部接口信号满足 Spec 的初始状态。
3. function 内无 return；无锁存器；无 typedef enum；无 class/interface/断言/动态数组。
4. 跨模块信号名称与位宽和计划完全一致，与相邻模块对接处无歧义。"""

CODER_SELF_CHECK_RV32I = """5. 停顿与冲刷：load-use 恰好暂停 1 拍且冻结取指；stall 期间各级 valid 保持；重定向只清 valid、不破坏正确在途指令；ECALL 在停顿期间不得被丢弃。
6. 停机与退休：halted/exit_code 按沿更新，不存在 halted=0 且 exit_code!=0 的周期；每条提交指令恰好一个单拍 retire 脉冲，停顿不重复、冲刷不计数。
7. 前递与冒险：EX/MEM 优先于 MEM/WB；load 结果只经 MEM/WB 前递；分支比较与 JALR 使用前递后的值。
8. 若模块含 dbg_bp_resolve/dbg_bp_mispredict/dbg_ooo_issue/dbg_ooo_bypass：事件单拍、来自真实内部状态、停顿不重复、冲刷不计数、不可伪造。"""

DIAGNOSER_SYSTEM_PROMPT = """You are the Diagnoser of a digital IC design agent.
A teacher-testbench run failed. You receive a filtered failure brief and a file inventory (paths and sizes only, no code contents).
Your job: identify the most likely root cause and select the few files that a Patch agent must inspect and modify.

Rules:
- Use only the evidence in the failure brief; never invent checks or errors that are not listed.
- Map each failing check to the module most likely responsible, using the plan's module responsibilities.
- Classify every failure as one of: functional (wrong data/control result), timing/protocol (reset, retire-pulse, halt-commit, stall/flush corner), or handshake (ready/valid misuse); the packet must state which and why in timing_notes.
- involved_files must be a subset of the manifest paths, ordered by suspicion, at most 6 entries.
- If the evidence cannot narrow the problem down, list every manifest path instead of guessing a single file.
- repair_constraints must restate the binding freezes from the plan (never rename ports/modules/files) plus anything the patch must preserve.
- Do not produce code. Return ONLY a JSON object:

{"category": "compile|simulation|timeout|mixed", "root_cause": "one short paragraph", "failing_checks": ["..."], "involved_files": ["rtl/..."], "repair_constraints": ["..."], "evidence": "short quotes or line references from the brief", "timing_notes": "which timing corners (reset/retire/halt/stall/forwarding/handshake) are suspect and why"}

The RV32I timing corners below are the reference knowledge base for classification:
"""

DIAGNOSER_SYSTEM_PROMPT += RV32I_TIMING_CONSTRAINTS + "\n" + RV32I_ADVANCED_TIMING

PATCH_SYSTEM_PROMPT = """You are the Patch Agent of a digital IC design agent.
A Diagnoser has compressed the latest teacher-TB failure into a failure packet. You receive that packet, the binding plan interfaces, and ONLY the current content of the involved files.
Your job: apply a minimal, root-cause repair to the involved files.

Rules:
- Modify only the involved files provided in this message; never invent files that were not provided.
- Match the Planner interfaces exactly. Never rename ports, modules, files, or parameters.
- For compile failures, fix every error in the packet's compiler output, including hierarchy/port/width errors.
- For simulation failures, use the packet's failing checks and evidence to fix the root cause; do not guess or weaken behavior.
- Preserve already-correct logic. A small targeted patch is better than rewriting the project.
- Do not add external IPs, simulation-only constructs, or modify the teacher TB.
- If the packet lists previous hypotheses that did not fix the problem, do not repeat them; change the implementation strategy.
- Before returning JSON, self-check each failing check from the packet AND the timing corners it implicates (reset values, retire-pulse uniqueness, halt/exit_code commit cycle, stall/flush valid handling, ready/valid stability); a patch that fixes the data path but breaks a timing corner is invalid.
- State the repair and the timing corners you verified in notes.
- At least one returned file MUST differ from the provided content; returning an unchanged file is an invalid no-op patch.
- Return ONLY a JSON object; no Markdown fences, no prose outside JSON.

Return schema:
{"files": [{"path": "rtl/foo.sv", "content": "full SystemVerilog file content"}], "notes": "short repair summary"}
You may return only files that need changes, but each returned file must contain its complete content.

"""

PATCH_SYSTEM_PROMPT += "\n\n" + RV32I_PIPELINE_CHECKLIST + "\n\n" + RV32I_L1_CODE_PATTERNS

MAX_PARSER_ROUNDS = 3
MAX_TEST_ATTEMPTS = 9
SV_PATH_PATTERN = re.compile(r"^[A-Za-z0-9_./-]+\.sv$")
MODULE_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def extract_json_payload(text: str) -> dict[str, Any]:
    """从模型回答中提取第一个 JSON 对象（兼容 ```json 围栏）。"""
    raw = (text or "").strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-zA-Z0-9_-]*\s*", "", raw)
        raw = re.sub(r"\s*```$", "", raw)
    try:
        payload = json.loads(raw)
        if isinstance(payload, dict):
            return payload
    except json.JSONDecodeError:
        pass
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        try:
            payload = json.loads(raw[start : end + 1])
            if isinstance(payload, dict):
                return payload
        except json.JSONDecodeError:
            pass
    raise ValueError("模型没有返回合法的 JSON 对象")


def safe_project_path(run_dir: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative.strip():
        raise ValueError("RTL 文件路径不能为空")
    relative = relative.strip().replace("\\", "/")
    if not SV_PATH_PATTERN.fullmatch(relative):
        raise ValueError(f"RTL 文件路径必须是相对 .sv 路径：{relative}")
    project_root = (run_dir / "project").resolve()
    candidate = (project_root / relative).resolve()
    if project_root not in candidate.parents:
        raise ValueError(f"RTL 文件路径越出项目目录：{relative}")
    return candidate


def validate_plan(payload: dict[str, Any]) -> dict[str, Any]:
    modules = payload.get("modules")
    if not isinstance(modules, list) or not modules:
        raise ValueError("Planner 没有返回 modules 列表")
    clean_modules: list[dict[str, str]] = []
    seen_names: set[str] = set()
    seen_files: set[str] = set()
    for item in modules:
        if not isinstance(item, dict):
            raise ValueError("Planner 的 module 条目格式无效")
        name = item.get("name")
        file = item.get("file")
        if not isinstance(name, str) or not MODULE_NAME_PATTERN.fullmatch(name):
            raise ValueError("Planner 返回了非法模块名")
        if name in seen_names:
            raise ValueError(f"Planner 重复声明模块：{name}")
        if not isinstance(file, str):
            raise ValueError("Planner 的模块缺少 file")
        file = file.strip().replace("\\", "/")
        if not SV_PATH_PATTERN.fullmatch(file):
            raise ValueError(f"Planner 返回了非法文件路径：{file}")
        if file in seen_files:
            raise ValueError(f"Planner 重复声明文件：{file}")
        seen_names.add(name)
        seen_files.add(file)
        clean_modules.append(
            {
                "name": name,
                "file": file,
                "description": str(item.get("description") or "")[:500],
                "interfaces": str(item.get("interfaces") or "")[:1000],
                "reuse": bool(item.get("reuse")),
            }
        )
    top_module = payload.get("top_module") or clean_modules[0]["name"]
    if not isinstance(top_module, str) or top_module not in seen_names:
        raise ValueError("Planner 的 top_module 不在 modules 中")
    return {
        "project_name": str(payload.get("project_name") or "agent_project")[:100],
        "top_module": top_module,
        "modules": clean_modules,
        "notes": str(payload.get("notes") or "")[:2000],
    }


def validate_modifier_files(payload: dict[str, Any], plan: dict[str, Any]) -> dict[str, str]:
    files = payload.get("files")
    if not isinstance(files, list) or not files:
        raise ValueError("Patch 没有返回 files 列表")
    allowed = {module["file"] for module in plan["modules"]}
    clean: dict[str, str] = {}
    for item in files:
        if not isinstance(item, dict):
            raise ValueError("Patch 的 file 条目格式无效")
        path = item.get("path")
        content = item.get("content")
        normalized = path.strip().replace("\\", "/") if isinstance(path, str) else ""
        if normalized not in allowed:
            raise ValueError(f"Patch 返回了计划之外的文件：{path}")
        if not isinstance(content, str) or "module" not in content:
            raise ValueError(f"Patch 为 {path} 返回的内容不是 RTL")
        clean[normalized] = content
    return clean


def combine_files(files: dict[str, str]) -> str:
    return "\n\n".join(f"// file: {path}\n{content}" for path, content in files.items()) + "\n"


def trace_mismatches(report: dict[str, Any]) -> list[str]:
    messages: list[str] = []
    for row in report.get("trace") or []:
        differences = []
        for key, value in row.items():
            if not key.startswith("expected_"):
                continue
            actual_key = key.removeprefix("expected_")
            actual = row.get(actual_key)
            if actual is None:
                actual = row.get(f"out_{actual_key}")
            if actual is not None and str(actual) != str(value):
                differences.append(f"{actual_key}={actual} (expected {value})")
        if differences:
            label = row.get("event") or row.get("case") or "sample"
            messages.append(f"cycle {row.get('cycle', '?')} · {label}: " + "，".join(differences))
    return messages[:12]


def report_feedback(report: dict[str, Any] | None) -> str:
    if report is None:
        return "Verification has not run for the previous round."
    if report.get("passed"):
        return "The previous teacher TB passed; preserve current behavior and finish the remaining steps."
    lines = [report_summary(report)]
    mismatches = trace_mismatches(report)
    if mismatches:
        lines.append("Failing cycles:")
        lines.extend(f"- {item}" for item in mismatches[:12])
    suites = [
        item.get("name") for item in (report.get("test_suites") or [])
        if item.get("name") and not item.get("passed") and not item.get("skipped")
    ]
    if suites:
        lines.append("Failing suites: " + ", ".join(suites))
    checks = report.get("checks") or []
    if checks:
        lines.append("Failed checks:")
        lines.extend(f"- {item.get('name')}: {item.get('detail', '')}".rstrip(": ") for item in checks[:20])
        if len(checks) > 20:
            lines.append(f"- ... {len(checks) - 20} additional failed checks omitted")
        timeout_count = sum("等待 halted 超时" in str(item.get("detail") or "") for item in checks)
        if timeout_count >= 2:
            lines.append(
                "HALT-TIMEOUT 诊断提示：多个测试都等到 halted 超时，且 imem_addr 仍在变化；"
                "请优先检查 ECALL 在 ID 级的识别、ID→EX→MEM→WB 的 is_ecall 传递、"
                "WB 的 halted/exit_code 更新、IF/流水线 halt 冻结，以及同步复位；"
                "不要只修 Cache 或单个数据通路。"
            )
    if report.get("stage") == "simulation" and checks:
        joined = "\n".join(f"{item.get('name')}: {item.get('detail', '')}" for item in checks)
        if "等待 halted 超时" in joined:
            lines.append(
                "HALT-TIMEOUT: 先检查单拍 resp_valid 是否被 wait 标志漏采、stall 时 IF/ID/ID-EX valid 是否被清、"
                "以及 ECALL 是否在 ID 冻结时被丢弃；不要先只改 Cache 数据通路。"
            )
        if "cache_instruction_reuse" in joined or "imem 请求" in joined or "I-memory request changed" in joined:
            lines.append(
                "ICACHE/REFILL: refill 期间 imem_valid/addr 必须保持到 imem_ready；不要 abort 在途 refill；"
                "完成后安装 line，仅用 epoch 抑制过期 response。"
            )
    if report.get("stage") == "compile":
        detail = (report.get("stderr") or report.get("stdout") or "").strip()
        if detail:
            lines.append("Compiler output (tail):")
            lines.append(detail[-3000:])
    return "\n".join(lines)


def build_failure_brief(report: dict[str, Any] | None) -> dict[str, Any]:
    """把教师 TB 报告压缩为 Diagnoser 可读的结构化失败简报。

    上下文纪律：仿真类只保留失败检查、失败 suite 与前若干条 trace 失配；
    编译类只保留编译器输出的最后一段；原始 stdout 与全量 trace 不进入简报。
    """
    if report is None:
        return {
            "stage": None,
            "summary": "Verification has not run for the previous round.",
            "failed_checks": [],
            "total_failed_checks": 0,
            "trace_mismatches": [],
            "failing_suites": [],
            "compile_error_tail": [],
            "hints": [],
            "return_code": None,
        }
    checks = report.get("checks") or []
    failed_checks = [
        {"name": str(item.get("name") or ""), "detail": str(item.get("detail") or "")[:300]}
        for item in checks[:12]
    ]
    lines = [report_summary(report)]
    hints: list[str] = []
    joined = "\n".join(str(item.get("detail") or "") for item in checks)
    timeout_count = sum("等待 halted 超时" in text for text in (str(item.get("detail") or "") for item in checks))
    if timeout_count >= 2:
        hints.append(
            "HALT-TIMEOUT: 多个测试等到 halted 超时且 imem_addr 仍在变化；"
            "优先检查 ECALL 在 ID 级的识别、is_ecall 经 ID→EX→MEM→WB 的传递、"
            "WB 的 halted/exit_code 提交、IF/流水线 halt 冻结与同步复位。"
        )
    if "cache_instruction_reuse" in joined or "imem 请求" in joined or "I-memory request changed" in joined:
        hints.append(
            "ICACHE/REFILL: refill 期间 imem_valid/addr 必须保持到 imem_ready；"
            "不要 abort 在途 refill；完成后安装 line，仅用 epoch 抑制过期 response。"
        )
    compile_tail: list[str] = []
    if report.get("stage") == "compile":
        detail = (report.get("stderr") or report.get("stdout") or "").strip()
        # iverilog 的 "sorry:" 是非致命警告（有等价回退），真正的失败原因在其余行。
        real_lines = [line for line in detail.splitlines() if "sorry:" not in line]
        compile_tail = real_lines[-40:]
        joined_real = "\n".join(real_lines)
        if "Unknown module type" in joined_real or "modules were missing" in joined_real:
            hints.append(
                "MODULE-MISSING: 有被例化的模块未定义。检查 plan.modules 是否遗漏了实现所必需的"
                "模块（如 ALU、乘法器等子模块）；若使用参考实现，确认其全部文件都已写入工程。"
            )
        if "is not a port of" in joined_real:
            hints.append(
                "PORT-MISMATCH: 例化端口与模块声明不一致——常见于复用模块与参考实现/新生成模块"
                "混用导致接口约定不同。以计划 interfaces 为准统一端口，或改用同一来源的实现。"
            )
    return {
        "stage": report.get("stage"),
        "summary": report_summary(report),
        "failed_checks": failed_checks,
        "total_failed_checks": len(checks),
        "trace_mismatches": trace_mismatches(report)[:8],
        "failing_suites": [
            item.get("name")
            for item in (report.get("test_suites") or [])
            if isinstance(item, dict) and item.get("name") and not item.get("passed") and not item.get("skipped")
        ],
        "compile_error_tail": compile_tail,
        "hints": hints,
        "return_code": report.get("return_code"),
    }


def project_feedback(files: dict[str, str], plan: dict[str, Any], report: dict[str, Any]) -> str:
    lines = [report_summary(report), "当前项目文件："]
    lines.extend(f"- {path} ({len(content)} chars)" for path, content in files.items())
    lines.append("计划模块：")
    lines.extend(f"- {module['name']} -> {module['file']}" for module in plan["modules"])
    lines.append("")
    lines.append(report_feedback(report))
    return "\n".join(lines)

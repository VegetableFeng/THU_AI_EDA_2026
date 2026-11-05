"""Tester 子 Agent：编译项目、运行教师 TB、评估面积 / 功耗。"""

from __future__ import annotations

from pathlib import Path

from ai_eda.agent.projects import get_project
from ai_eda.rtl.metrics import (
    find_missing_port_connections,
    find_wiring_faults,
    synthesis_gate,
)
from ai_eda.rtl.runner import save_report, test_rtl

from .base import SubAgent
from .common import combine_files, report_feedback, report_summary



class TesterAgent(SubAgent):
    name = "tester"
    title = "04 · Tester"
    node_type = "tester"

    def run(self, input_handoff: Path, attempt: int) -> Path:
        incoming = self.runtime.read_handoff(input_handoff)["payload"]
        artifacts = incoming.get("artifacts") or {}
        spec_ref = artifacts.get("spec")
        plan_ref = artifacts.get("plan")
        manifest_ref = artifacts.get("rtl_manifest")
        if not all(isinstance(ref, str) for ref in (spec_ref, plan_ref, manifest_ref)):
            raise ValueError("Tester 输入缺少 Spec、Plan 或 RTL manifest artifact")
        plan = self.runtime.read_json_artifact(plan_ref)
        manifest = self.runtime.read_json_artifact(manifest_ref)
        if not isinstance(plan, dict):
            raise ValueError("Plan artifact 格式无效")
        entries = manifest.get("files") if isinstance(manifest, dict) else None
        if not isinstance(entries, list) or not entries:
            raise ValueError("RTL manifest 格式无效")
        files: dict[str, str] = {}
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str) or not isinstance(entry.get("artifact"), str):
                raise ValueError("RTL manifest 含有无效文件引用")
            files[entry["path"]] = self.runtime.read_text_artifact(entry["artifact"])
        combined_ref = self.runtime.write_text_artifact(
            f"generated_attempt{attempt}.sv", combine_files(files)
        )
        combined_path = self.runtime.run_dir / combined_ref
        tester_dir = self.runtime.run_dir / f"tester-{attempt:02d}"
        tester_dir.mkdir(exist_ok=True)
        prompt = (
            f"Round {attempt}: compile {len(files)} project files and run the fixed teacher TB; "
            "generate power activity and synthesized area as well."
        )
        event = self.runtime.begin_event(
            "tester", self.node_type, f"{self.title} · Round {attempt}", prompt, attempt
        )
        project = self.runtime.options.get("project") or get_project()
        report = test_rtl(
            task_name=project["task_name"],
            testbench_path=project["testbench_path"],
            testbench_top=project["testbench_top"],
            rtl_path=combined_path,
            power_testbench_path=project["power_testbench_path"],
            power_testbench_top=project["power_testbench_top"],
            expected_cpu_level=project.get("expected_cpu_level"),
            rtl_top_module=plan.get("top_module"),
            timeout_seconds=int(project.get("timeout_seconds", 20)),
            run_dir=tester_dir,
        )
        self.check_cancel()
        report_path = save_report(tester_dir, report)
        # 连线静态检查：无驱动/多驱动信号是 freeze/timeout 类失败的隐藏根因。
        top_for_check = plan.get("top_module")
        if isinstance(top_for_check, str) and top_for_check:
            wiring = find_wiring_faults(combined_path, top_for_check)
            report["wiring_check"] = wiring
            checks = report.setdefault("checks", [])
            if wiring.get("undriven"):
                checks.insert(
                    0,
                    {
                        "name": "wiring_undriven_signals",
                        "detail": "无驱动信号（X 源）：" + "、".join(wiring["undriven"]),
                    },
                )
            if wiring.get("multi_driven"):
                checks.insert(
                    0,
                    {
                        "name": "wiring_multi_driven_signals",
                        "detail": "多驱动信号：" + "、".join(wiring["multi_driven"]),
                    },
                )
            # 可综合性门禁：PPA 指标以综合为前提；综合超时/报错视为失败检查，
            # 驱动 repair 循环把不可综合结构（如链式可变索引数组写）重构掉。
            synth = synthesis_gate(combined_path, top_for_check)
            report["synthesis_check"] = synth
            if synth.get("status") == "failed":
                checks.insert(
                    0,
                    {
                        "name": "synthesis_gate",
                        "detail": synth.get("reason", "yosys 综合失败"),
                    },
                )
                # 门禁失败必须翻转总体判定：TB 通过但不可综合 = 无法产出 PPA，
                # 仍属未完成，repair 循环需要继续重构。
                report["passed"] = False
            # PPA 预算门禁：TB PASS + 可综合之后，面积/功耗仍须落在预算内。
            # 超预算作为失败检查驱动 repair 循环做等价 PPA 重构。
            metrics = report.get("metrics") or {}
            area_budget = project.get("area_budget_um2")
            power_budget = project.get("power_budget_w")
            if metrics.get("status") == "ok" and area_budget:
                area_v = metrics.get("area")
                if isinstance(area_v, (int, float)) and area_v > area_budget:
                    checks.insert(
                        0,
                        {
                            "name": "ppa_area_budget",
                            "detail": (
                                f"面积 {area_v:.0f} 超预算 {area_budget}（ library 单位）。"
                                "按缺陷清单做等价重构：降低 checkpoint/表项冗余、砍 cache 行数、"
                                "去除无消费宽字段；TB 必须保持 PASS。"
                            ),
                        },
                    )
                    report["passed"] = False
            if metrics.get("status") == "ok" and power_budget:
                power_v = metrics.get("total_power_w")
                if isinstance(power_v, (int, float)) and power_v > power_budget:
                    checks.insert(
                        0,
                        {
                            "name": "ppa_power_budget",
                            "detail": (
                                f"总功耗 {power_v:.4f} W 超预算 {power_budget} W。"
                                "按缺陷清单做等价重构：大向量每拍无条件重写加写使能、"
                                "ALU 操作数隔离；TB 必须保持 PASS。"
                            ),
                        },
                    )
                    report["passed"] = False
            port_cover = find_missing_port_connections(combined_path)
            missing_conns = port_cover.get("missing_connections") or []
            for entry in missing_conns:
                checks.insert(
                    0,
                    {
                        "name": "wiring_missing_port_connections",
                        "detail": (
                            f"实例 {entry['instance']}（{entry['module']}）漏接端口："
                            + "、".join(entry["missing_ports"])
                            + "——漏接的输入端口在仿真中恒为 X，会静默破坏握手/停机逻辑。"
                        ),
                    },
                )
            report_path = save_report(tester_dir, report)
        self.save_context(
            attempts=int(self.context.get("attempts", 0)) + 1,
            plan_ref=plan_ref,
            rtl_manifest_ref=manifest_ref,
        )
        report_ref = self.runtime.artifact_ref(report_path)
        self.finish(
            event,
            "passed" if report.get("passed") else "failed",
            response=report_summary(report),
            report=report,
            feedback=report_feedback(report),
        )
        target = "summary" if report.get("passed") else "diagnoser"
        label = (
            "Tester → Summary: final report artifact"
            if report.get("passed")
            else "Tester → Diagnoser: failure report artifact"
        )
        return self.runtime.write_handoff(
            "tester",
            target,
            {
                "attempt": attempt,
                "summary": report_summary(report),
                "artifacts": {
                    "spec": spec_ref,
                    "plan": plan_ref,
                    "rtl_manifest": manifest_ref,
                    "report": report_ref,
                    "combined_rtl": combined_ref,
                },
            },
            attempt=attempt,
            label=label,
        )

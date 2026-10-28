"""Diagnoser 子 Agent：把筛选后的失败证据压缩为结构化 failure packet。

上下文纪律：Diagnoser 只读取失败简报与文件清单（路径 + 模块名 + 大小），
不读取任何 RTL 文件内容；它负责判断哪些文件与失败相关，并把结论写进
failure packet，供 Patch Agent 在最小文件集合上打补丁。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .base import SubAgent
from .common import (
    DIAGNOSER_SYSTEM_PROMPT,
    build_failure_brief,
    extract_json_payload,
)

VALID_CATEGORIES = {"compile", "simulation", "timeout", "mixed"}


class DiagnoserAgent(SubAgent):
    name = "diagnoser"
    title = "05 · Diagnoser"
    node_type = "model"
    # 诊断是根因分析而非工具型输出：显式开启思维链，独立于运行级开关。
    MODEL_OPTIONS = {"thinking": True}
    MAX_INVOLVED_FILES = 6

    def _previous_hypotheses(self, attempt: int) -> list[dict[str, Any]]:
        """收集此前各轮 packet 的根因，供本轮排除已被证伪的假设。"""
        hypotheses: list[dict[str, Any]] = []
        for earlier in range(1, attempt):
            path = self.runtime.artifacts_dir / f"failure_packet_attempt{earlier}.json"
            if not path.is_file():
                continue
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            cause = str((payload or {}).get("root_cause") or "").strip()
            if cause:
                hypotheses.append({"attempt": earlier, "root_cause": cause[:400]})
        return hypotheses

    def run(self, tester_handoff: Path, attempt: int) -> Path:
        incoming = self.runtime.read_handoff(tester_handoff)["payload"]
        artifacts = incoming.get("artifacts") or {}
        spec_ref = artifacts.get("spec")
        plan_ref = artifacts.get("plan")
        manifest_ref = artifacts.get("rtl_manifest")
        report_ref = artifacts.get("report")
        if not all(isinstance(ref, str) for ref in (plan_ref, manifest_ref, report_ref)):
            raise ValueError("Tester → Diagnoser handoff 缺少 plan/manifest/report artifact")

        report = self.runtime.read_json_artifact(report_ref)
        plan = self.runtime.read_json_artifact(plan_ref)
        manifest = self.runtime.read_json_artifact(manifest_ref)
        entries = manifest.get("files") if isinstance(manifest, dict) else None
        if not isinstance(plan, dict) or not isinstance(report, dict) or not isinstance(entries, list):
            raise ValueError("Diagnoser 输入 artifact 格式无效")

        module_by_file = {
            item["file"]: item["name"]
            for item in plan.get("modules", [])
            if isinstance(item, dict) and item.get("file")
        }
        inventory: list[dict[str, Any]] = []
        manifest_paths: list[str] = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                continue
            path = entry["path"]
            manifest_paths.append(path)
            inventory.append(
                {
                    "path": path,
                    "module": module_by_file.get(path, "?"),
                    "bytes": entry.get("bytes"),
                }
            )

        brief = build_failure_brief(report)
        previous = self._previous_hypotheses(attempt)
        interfaces = "\n".join(
            f"- {item['name']} ({item['file']}): {item.get('interfaces', '')}"
            for item in plan.get("modules", [])
            if isinstance(item, dict) and item.get("file")
        )
        prompt = (
            f"教师 TB 第 {attempt} 次验收失败。下面是筛选后的失败简报与项目文件清单"
            "（只有路径、模块名与大小，没有代码内容）。请定位根因，并从清单中选出"
            "修复所必须查看/修改的文件（最多 6 个，按嫌疑排序；证据不足以收窄时才列出全部文件）。\n"
            "分类要求：先判断失败属于功能（数据/控制结果错误）、时序（复位/停机提交/"
            "retire 脉冲/停顿冲刷时序角）还是握手（ready/valid 使用）类别，"
            "并写入 timing_notes——这决定 Patch 应该改数据通路还是改控制时序。\n\n"
            "失败简报：\n"
            + json.dumps(brief, ensure_ascii=False, indent=2)
            + "\n\n文件清单：\n"
            + json.dumps(inventory, ensure_ascii=False, indent=2)
            + "\n\n计划接口契约（修复约束：不得改名端口/模块/文件）：\n"
            + interfaces
            + (
                "\n\n此前已被证伪的根因假设（不得重复）：\n"
                + json.dumps(previous, ensure_ascii=False, indent=2)
                if previous
                else ""
            )
            + "\n\n请只返回约定的 JSON 对象。"
        )
        event = self.runtime.begin_event(
            "diagnoser", self.node_type, f"{self.title} · Round {attempt}", prompt, attempt
        )
        result = self.runtime.call_model(
            event, prompt, DIAGNOSER_SYSTEM_PROMPT, model_options=self.MODEL_OPTIONS
        )
        try:
            payload = extract_json_payload(result.get("answer") or "")
        except ValueError as error:
            raise ValueError(f"Diagnoser 返回格式无效：{error}") from error

        category = str(payload.get("category") or "mixed")
        if category not in VALID_CATEGORIES:
            category = "mixed"
        manifest_set = set(manifest_paths)
        seen: set[str] = set()
        involved: list[str] = []
        for candidate in payload.get("involved_files") or []:
            path = candidate.strip() if isinstance(candidate, str) else ""
            if path in manifest_set and path not in seen:
                seen.add(path)
                involved.append(path)
        fallback = not involved
        if fallback:
            involved = list(manifest_paths)

        packet = {
            "attempt": attempt,
            "category": category,
            "root_cause": str(payload.get("root_cause") or "")[:2000],
            "failing_checks": [str(item)[:300] for item in (payload.get("failing_checks") or [])][:12],
            "involved_files": involved,
            "involved_files_is_full_set": fallback,
            "repair_constraints": [str(item)[:400] for item in (payload.get("repair_constraints") or [])][:8],
            "evidence": str(payload.get("evidence") or "")[:2000],
            "previous_hypotheses": previous,
            "failure_brief": brief,
        }
        packet_ref = self.runtime.write_json_artifact(
            f"failure_packet_attempt{attempt}.json", packet
        )
        self.save_context(attempts=attempt, last_packet_ref=packet_ref)
        self.finish(
            event,
            "info",
            response=(
                f"failure packet：类别 {category}；涉及文件 {len(involved)} 个"
                + ("（证据不足，回退全清单）" if fallback else "")
                + f"；根因：{packet['root_cause'][:120]}"
            ),
            reasoning=event.get("reasoning"),
            usage=event.get("usage"),
        )
        return self.runtime.write_handoff(
            "diagnoser",
            "patch",
            {
                "attempt": attempt,
                "summary": packet["root_cause"][:200],
                "artifacts": {
                    "failure_packet": packet_ref,
                    "plan": plan_ref,
                    "rtl_manifest": manifest_ref,
                    **({"spec": spec_ref} if isinstance(spec_ref, str) else {}),
                },
            },
            attempt=attempt,
            label="Diagnoser → Patch: failure packet artifact",
        )

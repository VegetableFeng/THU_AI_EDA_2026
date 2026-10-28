"""Patch 子 Agent：在 failure packet 圈定的最小文件集合上做根因修复。

与旧 Modifier 的区别：不再持久化多轮对话、不再接收全工程快照与完整 Spec；
每轮修复的输入只有 failure packet、计划接口契约与 packet 圈定的涉及文件。
跨轮防重复由 packet 中的 previous_hypotheses 承担。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .base import SubAgent
from .common import (
    PATCH_SYSTEM_PROMPT,
    extract_json_payload,
    safe_project_path,
    validate_modifier_files,
)


def _effective_changes(
    changed: dict[str, str], current: dict[str, str]
) -> dict[str, str]:
    """过滤掉返回内容与当前文件完全相同的空补丁。"""
    result: dict[str, str] = {}
    for path, content in changed.items():
        if content != current.get(path):
            result[path] = content
    return result


class PatchAgent(SubAgent):
    name = "patch"
    title = "06 · Patch"
    node_type = "model"
    # 打补丁是工具型输出（完整文件内容）：关闭思维链，把输出预算留给代码。
    MODEL_OPTIONS = {"thinking": False}

    def run(self, diagnoser_handoff: Path, attempt: int) -> Path:
        incoming = self.runtime.read_handoff(diagnoser_handoff)["payload"]
        artifacts = incoming.get("artifacts") or {}
        packet_ref = artifacts.get("failure_packet")
        spec_ref = artifacts.get("spec")
        plan_ref = artifacts.get("plan")
        manifest_ref = artifacts.get("rtl_manifest")
        if not all(
            isinstance(ref, str) for ref in (packet_ref, spec_ref, plan_ref, manifest_ref)
        ):
            raise ValueError(
                "Diagnoser → Patch handoff 缺少 failure packet/spec/plan/manifest artifact"
            )

        packet = self.runtime.read_json_artifact(packet_ref)
        plan = self.runtime.read_json_artifact(plan_ref)
        manifest = self.runtime.read_json_artifact(manifest_ref)
        entries = manifest.get("files") if isinstance(manifest, dict) else None
        if not isinstance(packet, dict) or not isinstance(plan, dict) or not isinstance(entries, list):
            raise ValueError("Patch 输入 artifact 格式无效")

        current: dict[str, str] = {}
        for entry in entries:
            if (
                not isinstance(entry, dict)
                or not isinstance(entry.get("path"), str)
                or not isinstance(entry.get("artifact"), str)
            ):
                raise ValueError("RTL manifest 含有无效文件引用")
            current[entry["path"]] = self.runtime.read_text_artifact(entry["artifact"])

        manifest_paths = set(current)
        involved = [
            path for path in (packet.get("involved_files") or [])
            if isinstance(path, str) and path in manifest_paths
        ]
        if not involved:
            involved = sorted(current)
        files = {path: current[path] for path in involved}

        interfaces = "\n".join(
            f"- {item['name']} ({item['file']}): {item.get('interfaces', '')}"
            for item in plan.get("modules", [])
            if isinstance(item, dict) and item.get("file")
        )
        previous = packet.get("previous_hypotheses") or []
        prompt = (
            f"这是第 {attempt} 轮修复。Diagnoser 已把教师 TB 失败压缩为 failure packet，"
            "并选出了允许修改的涉及文件。请基于 packet 的根因与证据做最小修复。\n\n"
            "修复纪律：\n"
            "1. 只允许修改下面给出的涉及文件；每个返回文件必须是完整 SystemVerilog 内容。\n"
            "2. 严格遵守计划接口契约：不得改名端口/模块/文件。\n"
            "3. packet 的 repair_constraints 必须遵守；previous_hypotheses 是已被证伪的假设，不得重复。\n"
            "4. 对照 packet 的 failing_checks 逐项覆盖；不要为了通过而删除检查或伪造行为。\n"
            "5. 至少一个文件必须与当前内容不同（禁止空补丁）。\n"
            "6. 返回前按时序角自查：复位值、retire/停机提交的拍数、停顿与冲刷的 valid 处理、"
            "ready/valid 稳定性——修好数据通路但破坏时序角的补丁同样无效。\n\n"
            "Failure packet：\n"
            + json.dumps(packet, ensure_ascii=False, indent=2)
            + "\n\n计划接口契约：\n"
            + interfaces
            + "\n\n涉及文件的当前内容：\n"
            + json.dumps(files, ensure_ascii=False, indent=2)
            + "\n\n请只返回约定的 JSON 对象。"
        )
        event = self.runtime.begin_event(
            "patch", self.node_type, f"{self.title} · Round {attempt}", prompt, attempt
        )
        payload: dict[str, Any] = {}
        changed: dict[str, str] = {}
        last_error: ValueError | None = None
        last_answer = ""
        messages: list[dict[str, str]] = [
            {"role": "system", "content": PATCH_SYSTEM_PROMPT}
        ]

        for parse_attempt in range(1, 3):
            if parse_attempt == 1:
                messages.append({"role": "user", "content": prompt})
            else:
                # 重试必须保留原上下文（packet/接口/涉及文件），否则模型看不到任何输入。
                messages.extend(
                    [
                        {"role": "assistant", "content": last_answer},
                        {
                            "role": "user",
                            "content": (
                                f"上一次输出无效（{last_error}）。上面的 failure packet、"
                                "计划接口与涉及文件内容仍然有效；请基于同一上下文换一种"
                                "修复策略，只输出一个 JSON 对象（files 数组 + notes），"
                                "只允许修改涉及文件，且至少一个文件必须与当前内容不同。"
                            ),
                        },
                    ]
                )
            result = self.runtime.call_model_messages(
                event, messages, model_options=self.MODEL_OPTIONS
            )
            answer = result.get("answer") or ""
            last_answer = answer
            messages.append({"role": "assistant", "content": answer})
            try:
                payload = extract_json_payload(answer)
                changed = _effective_changes(validate_modifier_files(payload, plan), files)
                if not changed:
                    raise ValueError(
                        "Patch 返回的文件内容与当前内容完全相同，没有产生任何实际修改"
                    )
                outside = [path for path in changed if path not in files]
                if outside:
                    raise ValueError(
                        "Patch 返回了 failure packet 之外的文件：" + "、".join(outside)
                    )
                last_error = None
                break
            except ValueError as error:
                last_error = error
                event["patch_validation_error"] = str(error)

        if last_error is not None:
            raise ValueError(f"Patch 修复无效（连续 2 次未返回合法修改）：{last_error}") from last_error

        notes = str(payload.get("notes") or "")
        for relative, content in changed.items():
            target = safe_project_path(self.runtime.run_dir, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        artifact_dir = self.runtime.run_dir / f"step-{event['step']:02d}-{event['node_id']}"
        artifact_dir.mkdir(parents=True, exist_ok=True)
        for relative, content in changed.items():
            (artifact_dir / relative.replace("/", "_")).write_text(content, encoding="utf-8")
            current[relative] = content

        next_manifest_ref = self.runtime.write_json_artifact(
            f"rtl_manifest_attempt{attempt}.json",
            {
                "files": [
                    {
                        "path": path,
                        "artifact": self.runtime.artifact_ref(
                            safe_project_path(self.runtime.run_dir, path)
                        ),
                        "bytes": len(content.encode("utf-8")),
                    }
                    for path, content in current.items()
                ]
            },
        )
        self.save_context(
            attempts=attempt,
            last_packet_ref=packet_ref,
            notes=notes,
            changed_paths=sorted(changed),
        )
        self.finish(
            event,
            "info",
            response=f"修改了 {len(changed)} 个文件：" + "、".join(sorted(changed)),
            reasoning=event.get("reasoning"),
            usage=event.get("usage"),
        )
        return self.runtime.write_handoff(
            "patch",
            "tester",
            {
                "attempt": attempt,
                "changed_paths": sorted(changed),
                "notes": notes,
                "artifacts": {
                    "spec": spec_ref,
                    "plan": plan_ref,
                    "rtl_manifest": next_manifest_ref,
                },
            },
            attempt=attempt,
            label="Patch → Tester: updated RTL manifest",
        )

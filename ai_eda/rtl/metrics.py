"""基于 Yosys 映射与 OpenROAD/OpenSTA 的面积和功耗估算。"""

from __future__ import annotations

import importlib.util
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def _top_module(rtl_path: Path) -> str:
    match = re.search(r"\bmodule\s+([A-Za-z_]\w*)\s*\(", rtl_path.read_text(encoding="utf-8"))
    if not match:
        raise ValueError("无法从 RTL 中确定顶层模块名")
    return match.group(1)


def _library_path() -> Path | None:
    if importlib.util.find_spec("vpadanalyzer") is None:
        return None
    from vpadanalyzer import config

    return Path(config.__file__).with_name("gscl45nm.lib")


def _sta_executable() -> str | None:
    """优先使用本项目安装的独立 OpenSTA，再接受用户 PATH 中的 sta。"""
    local_sta = Path(__file__).resolve().parents[2] / ".tools" / "opensta" / "bin" / "sta"
    if local_sta.is_file() and local_sta.stat().st_mode & 0o111:
        return str(local_sta)
    return shutil.which("sta")


def _sta_safe_netlist(netlist_path: Path) -> Path:
    """把 Yosys 网表转换成 OpenSTA 的 Verilog 解析器能接受的写法。

    Yosys 会把模块内 function 的局部变量写成带源文件路径的转义标识符
    （例如 ``\\func$1/path/file.sv:12$3.c``），并给整型循环变量生成
    ``wire signed``。OpenSTA 的解析器对这两类写法都不兼容。这里统一把
    转义标识符重命名为 ``\\esc_N``，并去掉网表内部的 ``signed`` 关键字；
    标准单元网表本身不依赖有符号性，因此不影响功耗分析。
    """
    text = netlist_path.read_text(encoding="utf-8")
    rename: dict[str, str] = {}

    def replace_identifier(match: re.Match[str]) -> str:
        token = match.group(0)
        if token not in rename:
            rename[token] = f"\\esc_{len(rename)} "
        return rename[token]

    text = re.sub(r"\\[^\s]+", replace_identifier, text)
    text = re.sub(r"\b(wire|reg)\s+signed\b", r"\1", text)
    safe_path = netlist_path.with_name("mapped_sta.v")
    safe_path.write_text(text, encoding="utf-8")
    return safe_path


def _mapped_netlist(rtl_path: Path, library_path: Path, top_module: str, work_dir: Path) -> tuple[Path, float]:
    """将 RTL 映射为标准单元网表，并返回 Liberty 面积。"""
    netlist_path = work_dir / "mapped.v"
    script_path = work_dir / "synth.ys"
    script_path.write_text(
        "\n".join(
            (
                f'read_verilog -sv "{rtl_path.resolve()}"',
                f"hierarchy -check -top {top_module}",
                "proc; opt; fsm; opt; memory; opt",
                "techmap; opt",
                f'dfflibmap -liberty "{library_path}"',
                f'abc -liberty "{library_path}"',
                f'stat -liberty "{library_path}"',
                f'write_verilog -noattr "{netlist_path}"',
            )
        )
        + "\n",
        encoding="utf-8",
    )
    try:
        result = subprocess.run(
            ["yosys", "-s", str(script_path)], text=True, capture_output=True, check=False, timeout=300
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            "yosys 综合超时（300s）：RTL 存在令前端指数展开的结构"
            "（典型：链式可变索引数组写，如 arr[ptr++] = x 的未展开循环）。"
        ) from error
    output = result.stdout + result.stderr
    # `stat -liberty` 会先打印每个模块的 local area，再打印 design hierarchy 的
    # top area。多模块项目必须先匹配 "top module"，否则会把顶层 wrapper 的
    # local area=0 当成整个设计的面积。
    match = re.search(
        r"Chip area for top module '[^']+':\s*([0-9.]+)", output
    )
    if match is None:
        match = re.search(
            r"Chip area for module '[^']+':\s*([0-9.]+)", output
        )
    if result.returncode != 0 or match is None or not netlist_path.is_file():
        raise RuntimeError(f"Yosys 未能完成标准单元映射。\n{output[-4000:]}")
    return _sta_safe_netlist(netlist_path), float(match.group(1))


def _parse_power_report(report: str) -> dict[str, float] | None:
    """解析 OpenSTA `report_power` 的总计行；单位由 OpenSTA 固定为 W。"""
    matches = re.findall(
        r"(?im)^\s*total\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)(?:\s+[0-9.eE+-]+%)?\s*$",
        report,
    )
    if not matches:
        return None
    internal, switching, leakage, total = (float(value) for value in matches[-1])
    return {
        "internal_power_w": internal,
        "switching_power_w": switching,
        "dynamic_power_w": internal + switching,
        "leakage_power_w": leakage,
        "total_power_w": total,
    }


def synthesis_gate(rtl_path: Path, top_module: str, timeout_s: int = 150) -> dict[str, Any]:
    """可综合性门禁：yosys 必须能在限时内完成到 dfflibmap/abc 的映射。

    iverilog 能仿真的 RTL 未必能综合——前端对"链式可变索引数组写"等结构
    会指数展开（read_verilog 阶段即挂起）。PPA 指标以综合为前提，故把
    综合超时作为 tester 的失败检查项，驱动 repair 循环重构对应模块。
    """
    if shutil.which("yosys") is None:
        return {"status": "unavailable", "reason": "未找到 yosys。"}
    if not re.fullmatch(r"[A-Za-z_]\w*", top_module or ""):
        return {"status": "unavailable", "reason": "顶层模块名无效。"}
    library_path = _library_path()
    if library_path is None:
        return {"status": "unavailable", "reason": "未安装 Liberty 库。"}
    with tempfile.TemporaryDirectory(prefix="ai_eda_synthgate_") as temp_dir:
        netlist_path = Path(temp_dir) / "mapped.v"
        script_path = Path(temp_dir) / "synth.ys"
        script_path.write_text(
            "\n".join(
                (
                    f'read_verilog -sv "{rtl_path.resolve()}"',
                    f"hierarchy -check -top {top_module}",
                    "proc; opt; fsm; opt; memory; opt",
                    "techmap; opt",
                    f'dfflibmap -liberty "{library_path}"',
                    f'abc -liberty "{library_path}"',
                    f'stat -liberty "{library_path}"',
                )
            )
            + "\n",
            encoding="utf-8",
        )
        try:
            result = subprocess.run(
                ["yosys", "-s", str(script_path)],
                text=True,
                capture_output=True,
                check=False,
                timeout=timeout_s,
            )
        except subprocess.TimeoutExpired:
            return {
                "status": "failed",
                "reason": (
                    f"yosys 综合超时（{timeout_s}s）：RTL 含使前端/proc 指数展开的结构。"
                    "典型元凶：always 块内对展开数组的链式可变索引写"
                    "（arr[ptr] = x 后 ptr = ptr + 1 逐项推进）。"
                    "请重构为固定索引/位向量写法，保持 TB 行为不变。"
                ),
            }
        output = result.stdout + result.stderr
        if result.returncode != 0:
            tail_lines = [ln for ln in output.splitlines() if ln.strip()][-6:]
            return {"status": "failed", "reason": "yosys 综合报错：" + " | ".join(tail_lines)}
        area_match = re.search(
            r"Chip area for (?:top )?module '[^']+':\s*([0-9.]+)", output
        )
        return {
            "status": "ok",
            "area_um2": float(area_match.group(1)) if area_match else None,
        }


def synthesize_metrics(
    rtl_path: Path,
    *,
    vcd_path: Path | None = None,
    vcd_scope: str | None = None,
    top_module: str | None = None,
) -> dict[str, Any]:
    """评估映射面积，并在有 OpenROAD 和 VCD 时估算活动相关功耗。

    面积来自 Yosys 对同一 Liberty 的技术映射；功耗由独立 OpenSTA 读取
    门级网表、Liberty、SDC 与 VCD 后以瓦特报告。没有 LEF/DEF
    或 SPEF 时，这是前布局、无寄生参数的估算，而不是签核结果。
    """
    if shutil.which("yosys") is None:
        return {"status": "unavailable", "reason": "未找到 yosys；无法生成门级网表。"}
    library_path = _library_path()
    if library_path is None:
        return {"status": "unavailable", "reason": "未安装 verilog-pad-analyzer 的 Liberty 库。"}
    if not rtl_path.is_file():
        return {"status": "unavailable", "reason": f"RTL 不存在：{rtl_path}"}

    if top_module is not None and not re.fullmatch(r"[A-Za-z_]\w*", top_module):
        raise ValueError("RTL 顶层模块名无效")
    top_module = top_module or _top_module(rtl_path)
    with tempfile.TemporaryDirectory(prefix="ai_eda_metrics_") as temp_dir:
        work_dir = Path(temp_dir)
        try:
            netlist_path, area = _mapped_netlist(rtl_path, library_path, top_module, work_dir)
        except RuntimeError as error:
            return {"status": "failed", "reason": str(error)}

        metrics: dict[str, Any] = {
            "status": "area_only",
            "library": library_path.name,
            "top_module": top_module,
            "area": area,
            "area_unit": "library area units (gscl45nm)",
            "power_status": "unavailable",
            "power_reason": "需要 OpenSTA、VCD 活动文件与时钟约束。",
            "power_method": "OpenSTA gate-level VCD estimate",
        }
        sta = _sta_executable()
        if sta is None:
            metrics["power_reason"] = "未找到 sta；安装 OpenSTA 后重新运行 retest。"
            return metrics
        if vcd_path is None or not vcd_path.is_file() or not vcd_scope:
            metrics["power_reason"] = "未生成 VCD 活动文件；请重新运行带教师 TB 的实验。"
            return metrics

        sdc_path = work_dir / "clock.sdc"
        # 教师 TB 使用 10 ns 周期；后续可将时钟周期做成任务元数据。
        sdc_path.write_text("create_clock -name clk -period 10 [get_ports clk]\n", encoding="utf-8")
        script_path = work_dir / "power.tcl"
        script_path.write_text(
            "\n".join(
                (
                    f'read_liberty "{library_path}"',
                    f'read_verilog "{netlist_path}"',
                    f"link_design {top_module}",
                    f'read_sdc "{sdc_path}"',
                    f'read_vcd -scope {vcd_scope} "{vcd_path.resolve()}"',
                    "report_power",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        result = subprocess.run([sta, "-exit", str(script_path)], text=True, capture_output=True, check=False)
        output = result.stdout + result.stderr
        power = _parse_power_report(output)
        if result.returncode != 0 or power is None:
            metrics.update({
                "power_status": "failed",
                "power_reason": "OpenSTA 未能完成 VCD 功耗分析。",
                "opensta_output": output[-4000:],
            })
            return metrics
        metrics.update(power)
        metrics.update({"status": "ok", "power_status": "ok", "power_reason": None, "vcd_scope": vcd_scope})
        return metrics


def synthesize_area(rtl_path: Path) -> dict[str, Any]:
    """兼容旧调用；新代码应使用 :func:`synthesize_metrics`。"""
    return synthesize_metrics(rtl_path)


def find_missing_port_connections(rtl_path: Path) -> dict[str, Any]:
    """文本级端口覆盖检查：每个实例必须连接其模块声明的全部端口。

    iverilog 对漏接的实例输入端口**静默产出 X**（yosys check 也不报），
    是 freeze/timeout 类失败最隐蔽的根因（如 icache/dcache 的 halted、
    flush_epoch 漏接）。此检查对命名连接逐一比对模块端口集，报告缺失。
    """
    import re as _re

    src = rtl_path.read_text(encoding="utf-8")
    src = _re.sub(r"/\*.*?\*/", " ", src, flags=_re.DOTALL)
    src = _re.sub(r"//[^\n]*", " ", src)

    module_ports: dict[str, set[str]] = {}
    for m in _re.finditer(
        r"\bmodule\s+(\w+)\s*(?:#\([^)]*\))?\s*\((.*?)\)\s*;", src, flags=_re.DOTALL
    ):
        name = m.group(1)
        ports: set[str] = set()
        for pm in _re.finditer(
            r"\b(?:input|output|inout)\b[^,;()]*?\b(\w+)\s*(?:,|$)",
            m.group(2),
            flags=_re.DOTALL,
        ):
            ports.add(pm.group(1))
        module_ports[name] = ports

    missing_report: list[dict[str, Any]] = []
    inst_re = _re.compile(
        r"\b([A-Za-z_]\w*)\s+(?:#\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\((.*?)\)\s*;",
        flags=_re.DOTALL,
    )
    for im in inst_re.finditer(src):
        mod_name, inst_name, body = im.group(1), im.group(2), im.group(3)
        if mod_name in ("module", "if", "case") or mod_name not in module_ports:
            continue
        connected = set(_re.findall(r"\.(\w+)\s*\(", body))
        missing = module_ports[mod_name] - connected
        if missing:
            missing_report.append(
                {
                    "module": mod_name,
                    "instance": inst_name,
                    "missing_ports": sorted(missing),
                }
            )
    return {"status": "ok", "missing_connections": missing_report}


def find_wiring_faults(rtl_path: Path, top_module: str) -> dict[str, Any]:
    """用 yosys 静态检测悬空（无驱动）与多驱动信号。

    iverilog 对未连接的实例端口和无驱动的内部 wire 静默产出 X，是 freeze/
    timeout 类失败的常见根因且教师 TB 输出不可见；yosys 的 `check` 能在
    综合前直接报告这两类连线缺陷。yosys 不可用时返回 unavailable。
    """
    if shutil.which("yosys") is None:
        return {"status": "unavailable", "reason": "未找到 yosys。"}
    if not re.fullmatch(r"[A-Za-z_]\w*", top_module or ""):
        return {"status": "unavailable", "reason": "顶层模块名无效。"}
    with tempfile.TemporaryDirectory(prefix="ai_eda_wiring_") as temp_dir:
        script = Path(temp_dir) / "check.ys"
        script.write_text(
            "\n".join(
                (
                    f"read_verilog -sv {rtl_path}",
                    f"hierarchy -top {top_module}",
                    "proc; opt_clean",
                    "check",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        try:
            result = subprocess.run(
                ["yosys", "-s", str(script)], text=True, capture_output=True, check=False, timeout=150
            )
        except subprocess.TimeoutExpired:
            # 部分RTL（如大型 always_comb 阵列链）会让 yosys proc 阶段病态变慢。
            # 连线检查只是辅助诊断，超时应优雅降级为 unavailable，不得阻断教师 TB 流程。
            return {
                "status": "unavailable",
                "reason": "yosys 连线检查超时（150s），跳过静态连线诊断，继续仿真验证。",
            }
        output = result.stdout + result.stderr
        undriven: list[str] = []
        multi: list[str] = []
        for line in output.splitlines():
            line = line.strip()
            m = re.search(r"Wire (\S+) is used but has no driver", line)
            if m:
                undriven.append(m.group(1).split(".")[-1])
                continue
            m = re.search(r"Wire (\S+) (?:is|has) .*(?:multiple drivers|driven multiple times)", line)
            if m:
                multi.append(m.group(1).split(".")[-1])
        status = "ok" if result.returncode == 0 else "failed"
        return {
            "status": status,
            "undriven": sorted(set(undriven))[:20],
            "multi_driven": sorted(set(multi))[:20],
        }

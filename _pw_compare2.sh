#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
STA=/home/lenovo/.local/bin/sta
LIB=$BASE/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
RUN=$BASE/runs/prompt/homework_aes128/hw-20261028T045027074838
cd /tmp/pw
# 用 metrics.py 同款流程：_sta_safe_netlist 转换（这是课程流程真正用的网表形式）
python3 - << "PYEOF"
import sys
sys.path.insert(0, "/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026")
from ai_eda.rtl.metrics import _sta_safe_netlist
from pathlib import Path
import ai_eda.rtl.metrics as m
# 走 synthesize_metrics 的完整流程生成安全网表
import tempfile
src = Path("/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026/runs/prompt/homework_aes128/hw-20261028T045027074838/generated.sv")
LIB = "/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib"
r = m._mapped_netlist(src, LIB, "aes128", Path("/tmp/pw"))
netlist, area = r
print("mapped area:", area)
import shutil
shutil.copy(netlist, "/tmp/pw/netlist_safe.v")
print("copied to /tmp/pw/netlist_safe.v")
PYEOF
cat > t1.tcl << "TCL"
read_liberty LIB
read_verilog netlist_safe.v
link_design aes128
create_clock -name clk -period 10 [get_ports clk]
report_power
TCL
sed -i "s|LIB|$LIB|" t1.tcl
echo "=== 无 VCD（默认活动）==="
$STA -exit t1.tcl 2>&1 | tail -6
cp $RUN/activity.vcd /tmp/pw/ 2>/dev/null
cat > t2.tcl << "TCL"
read_liberty LIB
read_verilog netlist_safe.v
link_design aes128
create_clock -name clk -period 10 [get_ports clk]
read_vcd -scope tb_power_homework_aes128/dut /tmp/pw/activity.vcd
report_power
TCL
echo "=== 有 VCD（真实活动注记）==="
$STA -exit t2.tcl 2>&1 | tail -6

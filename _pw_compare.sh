#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
STA=/home/lenovo/.local/bin/sta
LIB=$BASE/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
RUN=$BASE/runs/prompt/homework_aes128/hw-20261028T045027074838
cd /tmp/pw
yosys -p "read_verilog -sv $RUN/generated.sv; hierarchy -top aes128; proc; opt; techmap; opt; dfflibmap -liberty $LIB; abc -liberty $LIB; write_verilog -noattr netlist.v" > /dev/null 2>&1

# 无 VCD（默认活动）vs 有 VCD（真实活动注记）对照
cat > t1.tcl << "TCL"
read_liberty LIB
read_verilog netlist.v
link_design aes128
create_clock -name clk -period 10 [get_ports clk]
report_power
TCL
cat > t2.tcl << "TCL"
read_liberty LIB
read_verilog netlist.v
link_design aes128
create_clock -name clk -period 10 [get_ports clk]
read_vcd -scope tb_power_homework_aes128/dut VCD
report_power
TCL
sed -i "s|LIB|$LIB|" t1.tcl
sed -i "s|LIB|$LIB|; s|VCD|$RUN/activity.vcd|" t2.tcl
echo "=== 无 VCD（默认活动）==="
$STA -exit t1.tcl 2>&1 | grep -iE "total|dynamic"
echo "=== 有 VCD（真实活动注记）==="
$STA -exit t2.tcl 2>&1 | grep -iE "total|dynamic"
echo "=== netlist 门数 ==="
grep -c "input\|output" netlist.v > /dev/null; yosys -p "read_verilog netlist.v; stat" 2>/dev/null | grep "Number of cells" | head -1

#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
STA=/home/lenovo/.local/bin/sta
LIB=$BASE/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
RUN=$BASE/runs/prompt/homework_aes128/hw-20261028T032602074838
cd /tmp/pw
VCD=$(ls $RUN/*.vcd 2>/dev/null | head -1)
echo "vcd: $VCD"
yosys -p "read_verilog -sv $RUN/generated.sv; hierarchy -top aes128; proc; opt; techmap; opt; dfflibmap -liberty $LIB; abc -liberty $LIB; write_verilog -noattr netlist.v" > /dev/null 2>&1
cat > pw.tcl << "TCL"
read_liberty LIBPATH
read_verilog netlist.v
link_design aes128
create_clock -name clk -period 10 [get_ports clk]
read_vcd -scope tb_power_homework_aes128/dut VCDPATH
report_power
TCL
sed -i "s|LIBPATH|$LIB|; s|VCDPATH|$VCD|" pw.tcl
$STA -exit pw.tcl 2>&1 | tail -25

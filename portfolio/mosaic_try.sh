#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
TB=$BASE/content/tasks/homework_rv32i5
C=$BASE/runs/agent/agent-20261104T165552175590/project/rtl
W=$(mktemp -d)
cp $BASE/submission/l3_final_rtl/*.sv $W/
cp $C/physical_register_file.sv $W/
cat $W/*.sv > $W/all.sv
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -s tb_agent_rv32i5 -o /dev/null $TB/tb.sv $W/all.sv 2>&1 | grep -i error | head -4
rm -rf $W

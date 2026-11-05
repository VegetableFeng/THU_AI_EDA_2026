#!/bin/bash
# 马赛克全验：TB + 综合
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
TB=$BASE/content/tasks/homework_rv32i5
LIB=$BASE/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
W=$(mktemp -d)
cp $BASE/portfolio/mosaic/*.sv $W/
cat $W/*.sv > $W/all.sv
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -s tb_agent_rv32i5 -o $W/tb.vvp $TB/tb.sv $W/all.sv 2>/dev/null || { echo COMPILE_FAIL; exit 1; }
timeout 400 vvp $W/tb.vvp 2>/dev/null | grep -E "LAB_RESULT|CAPABILITY"
printf 'read_verilog -sv %s/all.sv\nhierarchy -check -top rv32i5\nproc; opt; fsm; opt; memory; opt\ntechmap; opt\ndfflibmap -liberty "%s"\nabc -liberty "%s"\nstat -liberty "%s"\n' "$W" "$LIB" "$LIB" "$LIB" > $W/s.ys
timeout 400 yosys -s $W/s.ys 2>&1 | grep -E "Chip area for (top )?module" | tail -1
rm -rf $W

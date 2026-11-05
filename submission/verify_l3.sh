#!/bin/bash
# L3 提交物一键复验：教师 TB 全量 + yosys 面积。任何机器任何时间跑这条即可重新证明。
# 用法: bash submission/verify_l3.sh   （在 WSL 内，或经 wsl.exe 调用）
set -e
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
RTL=$BASE/submission/l3_final_rtl
TB=$BASE/content/tasks/homework_rv32i5
LIB=$BASE/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
W=$(mktemp -d)
cp $RTL/*.sv $W/
cat $W/*.sv > $W/all.sv
echo "== 教师 TB 全量验收 =="
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -s tb_agent_rv32i5 -o $W/tb.vvp $TB/tb.sv $W/all.sv
timeout 400 vvp $W/tb.vvp | grep -E "LAB_RESULT|CAPABILITY"
echo "== yosys 面积 =="
printf 'read_verilog -sv %s/all.sv\nhierarchy -check -top rv32i5\nproc; opt; fsm; opt; memory; opt\ntechmap; opt\ndfflibmap -liberty "%s"\nabc -liberty "%s"\nstat -liberty "%s"\n' "$W" "$LIB" "$LIB" "$LIB" > $W/s.ys
timeout 400 yosys -s $W/s.ys 2>&1 | grep -E "Chip area for (top )?module" | tail -1
echo "== 期望: PASS(21 tests) verified=3 面积≈215820 =="
rm -rf $W

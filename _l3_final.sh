#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
RTL=$BASE/runs/agent/agent-20261103T155135456546/project/rtl
TB=$BASE/content/tasks/homework_rv32i5
LIB=$BASE/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
cd /tmp
rm -rf /tmp/yfin; mkdir -p /tmp/yfin
n=0
for f in $RTL/*.sv; do n=$((n+1)); cp "$f" /tmp/yfin/c_$n.sv; done
cat /tmp/yfin/c_*.sv > /tmp/yfin/all.sv
# 1) 教师 TB
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -s tb_agent_rv32i5 -o /tmp/yfin/tb.vvp \
  $TB/tb.sv /tmp/yfin/all.sv > /tmp/yfin/tbc.log 2>&1
if [ $? -ne 0 ]; then echo COMPILE_FAIL; grep -iE "error" /tmp/yfin/tbc.log | head -3; exit 1; fi
timeout 400 vvp /tmp/yfin/tb.vvp > /tmp/yfin/sim.log 2>&1
grep -E "LAB_RESULT|CAPABILITY" /tmp/yfin/sim.log
# 2) 综合 + 每模块面积
printf 'read_verilog -sv /tmp/yfin/all.sv\nhierarchy -check -top rv32i5\nproc; opt; fsm; opt; memory; opt\ntechmap; opt\ndfflibmap -liberty "%s"\nabc -liberty "%s"\nstat -liberty "%s"\n' "$LIB" "$LIB" "$LIB" > /tmp/yfin/s.ys
S=$(date +%s); timeout 400 yosys -s /tmp/yfin/s.ys > /tmp/yfin/syn.log 2>&1; RC=$?; E=$(date +%s)
echo "synth rc=$RC $((E-S))s"
grep "Chip area for module" /tmp/yfin/syn.log

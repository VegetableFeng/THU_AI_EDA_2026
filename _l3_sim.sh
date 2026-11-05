#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
RTL=$BASE/runs/agent/agent-20261101T141539730076/project/rtl
TB=$BASE/content/tasks/homework_rv32i5
cd /tmp
cat $RTL/*.sv > /tmp/ag_all.sv
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -s tb_agent_rv32i5 -o ag.vvp \
  $TB/tb.sv /tmp/ag_all.sv > /tmp/ag_c.log 2>&1
RC=$?
if [ $RC -ne 0 ]; then echo COMPILE_FAIL; grep -iE "error" /tmp/ag_c.log | head -4; exit 1; fi
timeout 110 vvp ag.vvp > /tmp/ag_sim.log 2>&1
grep -E "LAB_RESULT|CAPABILITY" /tmp/ag_sim.log
grep "CHECK:" /tmp/ag_sim.log | sed 's/0x[0-9a-fx]*/H/g' | sort | uniq -c | sort -rn | head -12

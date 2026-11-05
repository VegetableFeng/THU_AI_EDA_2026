#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
REF=$BASE/content/agent/skills/rv32i5_l3_reference
TB=$BASE/content/tasks/homework_rv32i5
cd /tmp
rm -f l3test.vvp
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -o l3test.vvp \
  $TB/tb.sv \
  $REF/rv32i5_new.sv $REF/rename_unit.sv $REF/issue_queue.sv \
  $REF/reorder_buffer.sv $REF/load_store_unit.sv $REF/physical_regfile.sv \
  $REF/execute_unit.sv $REF/frontend.sv $REF/branch_predictor.sv \
  $REF/icache.sv $REF/dcache.sv $REF/alu.sv \
  2>/tmp/l3c.log
echo "compile rc=$?"
if [ -f l3test.vvp ]; then
  echo "vvp created"
  timeout 240 vvp l3test.vvp > /tmp/l3s.out 2>&1
  echo "sim rc=$?"
  grep "LAB_RESULT" /tmp/l3s.out | tail -1
  grep "^CHECK" /tmp/l3s.out | head -5
  echo "total checks: $(grep -c '^CHECK' /tmp/l3s.out 2>/dev/null)"
else
  echo "NO VVP - compile failed"
  grep -vE "sorry|warning" /tmp/l3c.log | grep -vE "^\s*:|^\s*$" | head -10
fi

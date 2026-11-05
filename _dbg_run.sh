#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
REF=$BASE/content/agent/skills/rv32i5_l3_reference
TB=$BASE/content/tasks/homework_rv32i5
cd /tmp
rm -f dbg.vvp
iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -s top -o dbg.vvp \
  $TB/tb.sv $REF/rv32i5_new.sv $REF/rename_unit.sv $REF/issue_queue.sv \
  $REF/reorder_buffer.sv $REF/load_store_unit.sv $REF/physical_regfile.sv \
  $REF/execute_unit.sv $REF/frontend.sv $REF/branch_predictor.sv \
  $REF/icache.sv $REF/dcache.sv $REF/alu.sv $BASE/_dbg_probe.sv \
  > /tmp/dbg_c.log 2>&1
RC=$?
if [ $RC -ne 0 ] || [ ! -f dbg.vvp ]; then echo "COMPILE FAILED rc=$RC"; grep -iE "error" /tmp/dbg_c.log | head -8; exit 1; fi
timeout 120 vvp dbg.vvp > /tmp/full_sim.log 2>&1
grep "LAB_RESULT" /tmp/full_sim.log
grep -c "^D|" /tmp/full_sim.log

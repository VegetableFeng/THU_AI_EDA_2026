#!/bin/bash
LIB=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026/.venv/lib/python3.14/site-packages/vpadanalyzer/config/gscl45nm.lib
run_stage() {
  printf 'read_verilog -sv /tmp/l3r5.sv\nhierarchy -check -top rv32i5\n%s\n' "$1" > /tmp/ys.ys
  S=$(date +%s); timeout 90 yosys -s /tmp/ys.ys > /tmp/ys.log 2>&1; RC=$?; E=$(date +%s)
  echo "[$1] rc=$RC $((E-S))s"
}
run_stage "proc"
run_stage "proc; opt"
run_stage "proc; opt; fsm; opt"
run_stage "proc; opt; fsm; opt; memory; opt"
run_stage "proc; opt; fsm; opt; memory; opt; techmap; opt"

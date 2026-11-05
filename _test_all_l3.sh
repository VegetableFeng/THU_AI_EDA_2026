#!/bin/bash
BASE=/mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
TB=$BASE/content/tasks/homework_rv32i5
cd /tmp

# 测试每个 L3 run 的 RTL 能否编译通过（无 sorry 阻塞）
for run in agent-20261031T063718082493 agent-20261031T012130730550 agent-20261031T131424613728 agent-20261031T132700784966 agent-20261031T014455170610 agent-20261030T151602946743; do
  RTL=$BASE/runs/agent/$run/project/rtl
  if [ ! -d "$RTL" ]; then echo "$run: NO RTL"; continue; fi
  NFLIST=$(ls $RTL/*.sv 2>/dev/null | wc -l)
  # 合并所有 sv 为一个文件
  cat $RTL/*.sv > /tmp/test_combined.sv 2>/dev/null
  # 编译
  iverilog -g2012 -DRV32I_FEATURE_PORTS -I $TB -o /tmp/test_$run.vvp \
    $TB/tb.sv /tmp/test_combined.sv > /tmp/test_c.log 2>&1
  RC=$?
  NSORRY=$(grep -c "sorry" /tmp/test_c.log 2>/dev/null)
  NERR=$(grep -c "error" /tmp/test_c.log 2>/dev/null)
  HASVVP="NO"
  [ -f /tmp/test_$run.vvp ] && HASVVP="YES"
  echo "$run: files=$NFLIST rc=$RC sorry=$NSORRY err=$NERR vvp=$HASVVP"
done

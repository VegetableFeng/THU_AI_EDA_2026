#!/bin/bash
# 岛屿式 PPA 优化 launcher（FunSearch 式岛屿模型）
# 用法: bash portfolio/run_islands.sh A|B|C   （Git Bash 侧运行）
# 每岛: 复制指令 → 提交作业（预算覆盖）→ 轮询 → 记录结果 + 每模块面积
set -u
BASE="$(cd "$(dirname "$0")/.." && pwd)"
ISL="${1:-A}"

CHAMPION="${2:-agent-20261103T172733151244}"
AREA_BUDGET=190000
POWER_BUDGET=0.020
URL=http://127.0.0.1:8000

echo "[island $ISL] directive -> ACTIVE_DEFECTS.md"
cp "$BASE/portfolio/island_$ISL.md" "$BASE/content/agent/skills/rv32i5_l3_reference/ACTIVE_DEFECTS.md"

echo "[island $ISL] submitting job (budgets: area<$AREA_BUDGET power<$POWER_BUDGET)"
RESP=$(curl -s -m 15 -X POST $URL/api/agent/jobs -H "Content-Type: application/json" -d "{
  \"project_id\":\"rv32i5_ooo\",\"thinking\":true,\"reasoning_effort\":\"max\",
  \"max_repair_attempts\":8,\"max_calls\":200,\"max_tokens\":300000,
  \"node_thinking\":{\"diagnoser\":true,\"patch\":true},
  \"resume_from\":\"$CHAMPION\",
  \"area_budget_um2\":$AREA_BUDGET,\"power_budget_w\":$POWER_BUDGET}")
echo "$RESP"
JOB=$(echo "$RESP" | python -c "import json,sys; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null)
[ -z "$JOB" ] && { echo "SUBMIT_FAILED"; exit 1; }
echo "[island $ISL] job=$JOB"

while true; do
  sleep 300
  ST=$(curl -s -m 8 $URL/api/agent/jobs/$JOB -o "$BASE/portfolio/_job_$ISL.json" -w "%{http_code}" 2>/dev/null)
  if [ "$ST" != "200" ]; then
    echo "[island $ISL] SERVER_DOWN (http=$ST)"; exit 2
  fi
  STATUS=$(python -c "import json; print(json.load(open(r'$BASE/portfolio/_job_$ISL.json',encoding='utf-8')).get('status'))" 2>/dev/null)
  echo "[island $ISL] status=$STATUS $(date +%H:%M)"
  [ "$STATUS" = "completed" ] || [ "$STATUS" = "failed" ] || [ "$STATUS" = "cancelled" ] && break
done

RUN=$(python -c "import json; print(json.load(open(r'$BASE/portfolio/_job_$ISL.json',encoding='utf-8')).get('run_id',''))")
echo "[island $ISL] finished status=$STATUS run=$RUN"
echo "$ISL $STATUS $RUN $JOB" >> "$BASE/portfolio/hof.log"

if [ "$STATUS" = "completed" ] && [ -n "$RUN" ]; then
  RD="$BASE/runs/agent/$RUN"
  mkdir -p "$BASE/portfolio/island_$ISL"
  cp $RD/project/rtl/*.sv "$BASE/portfolio/island_$ISL/" 2>/dev/null
  python - "$RD" <<'PY'
import json, sys, glob
rd = sys.argv[1]
reps = sorted(glob.glob(rd + '/tester-*/test_report.json'))
if reps:
    rep = json.load(open(reps[-1], encoding='utf-8'))
    m = rep.get('metrics') or {}
    print(f"FINAL area={m.get('area')} power={m.get('total_power_w')} passed={rep.get('passed')}")
PY
fi

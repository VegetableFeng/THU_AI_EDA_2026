#!/bin/bash
cd /mnt/f/MyDesktop/研一上/人工智能电路设计/THU_AI_EDA_2026
pkill -f "ai_eda serve" 2>/dev/null
sleep 1
( .venv/bin/python -m ai_eda serve --host 127.0.0.1 --port 8000 > /tmp/web.log 2>&1 & )
sleep 8
curl -s --max-time 5 -o /dev/null -w "server:%{http_code}\n" http://127.0.0.1:8000/api/agent/runs
python3 << "PYEOF"
import json, urllib.request
data = json.dumps({
  "project_id": "rv32i5_ooo",
  "resume_from": "agent-20261028T124341881041",
  "reasoning_effort": "max",
  "max_repair_attempts": 10,
  "max_calls": 240,
  "max_tokens": 200000,
  "temperature": 0.2,
  "node_thinking": {"parser": True, "planner": True, "coder": False, "diagnoser": True, "patch": True},
}).encode()
req = urllib.request.Request("http://127.0.0.1:8000/api/agent/jobs", data=data,
                             headers={"Content-Type": "application/json"})
print("job:", urllib.request.urlopen(req, timeout=20).read().decode())
PYEOF
exit 0

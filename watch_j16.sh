#!/bin/bash
for i in $(seq 1 90); do
  sleep 120
  curl -s --max-time 8 http://127.0.0.1:8000/api/agent/jobs/6ccdc7f14397 -o /tmp/j16.json 2>/dev/null
  ST=$(grep -o '"status": "[a-z_]*"' /tmp/j16.json 2>/dev/null | head -1)
  N=$(grep -o '"events": [0-9]*' /tmp/j16.json 2>/dev/null | head -1)
  echo "[$i] $ST $N"
  case "$ST" in
    *passed*|*failed*|*cancelled*) echo FINAL; break;;
  esac
done

#!/bin/bash
for i in $(seq 1 100); do
  sleep 120
  curl -s --max-time 8 http://127.0.0.1:8000/api/agent/jobs/e03b12049fc8 -o /tmp/jl3c.json 2>/dev/null
  ST=$(grep -o '"status": "[a-z_]*"' /tmp/jl3c.json 2>/dev/null | head -1)
  echo "[$i] $ST"
  case "$ST" in
    *passed*|*failed*|*cancelled*) echo FINAL; break;;
  esac
done

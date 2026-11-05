#!/bin/bash
for i in $(seq 1 100); do
  sleep 120
  curl -s --max-time 8 http://127.0.0.1:8000/api/agent/jobs -o /dev/null 2>/dev/null
  D=$(ls -t runs/agent/agent-*/events.json 2>/dev/null | head -1)
  ST=$(python -c "
import json, io
d = json.load(io.open(r'$D', encoding='utf-8'))
evs = d.get('events') or []
last = evs[-1] if evs else {}
print(d.get('status'), '| ev:', len(evs), '| last:', last.get('node_id'), last.get('status'), 'att', last.get('attempt'))
" 2>/dev/null)
  echo "[$i] $ST"
  case "$ST" in
    passed*|failed*|cancelled*) echo FINAL; break;;
  esac
done

#!/bin/bash
grep -o "ERROR.*" /tmp/ywork/ys.log | head -2
grep -n "rename_next" /tmp/ywork/ru.sv | head -4

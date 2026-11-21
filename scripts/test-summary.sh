#!/bin/bash
# 从测试日志里挑出结果行（日志里有大量系统噪音）。用法：scripts/test-summary.sh [日志，默认 /tmp/yilan-test.log]
grep -aE "^✔ Test run|^✘|^\*\* TEST|^Restarting|: error: " "${1:-/tmp/yilan-test.log}" | head -40

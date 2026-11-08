#!/bin/bash
for d in /home/dxw/arm_logs/*/; do
  f="$d/full_bringup.log"
  [ -f "$f" ] || continue
  echo "== $d"
  printf 'lines=%s ' "$(wc -l < "$f")"
  printf 'FailProgress=%s ' "$(grep -c 'Failed to make progress' "$f")"
  printf 'BeginNav=%s ' "$(grep -c 'Begin navigating from' "$f")"
  printf 'GoalOk=%s ' "$(grep -c 'Goal succeeded' "$f")"
  printf 'GoalFail=%s ' "$(grep -c 'Goal failed' "$f")"
  printf 'Spin=%s ' "$(grep -c 'Spin' "$f")"
  printf 'BackUp=%s ' "$(grep -c 'BackUp' "$f")"
  printf 'NewPath=%s\n' "$(grep -c 'Passing new path to controller' "$f")"
done

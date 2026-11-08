#!/bin/bash
for d in 20261107-225451 20261107-230821 20261107-231323; do
  f="/home/dxw/arm_logs/$d/full_bringup.log"
  echo "== $d"
  grep -n 'Failed to make progress' "$f" | head -12
  echo "-- first/last Begin navigating"
  grep -n 'Begin navigating from' "$f" | head -3
  grep -n 'Begin navigating from' "$f" | tail -3
  echo "-- Goal succeeded count lines sample"
  grep -n 'Goal succeeded' "$f" | tail -3
done

#!/bin/bash
source /opt/ros/jazzy/setup.bash >/dev/null 2>&1
source /home/dxw/amr/amr_sim_ws/install/setup.bash >/dev/null 2>&1
for i in $(seq 1 90); do
  t=$(timeout 3 ros2 topic echo /clock --once 2>/dev/null | head -1)
  [ -n "$t" ] && break
  sleep 2
done
echo "clock_ok=${t:+yes} try=$i"
for i in $(seq 1 60); do
  if timeout 5 ros2 topic echo /amcl_pose --once 2>/dev/null | head -2 | grep -q frame_id; then
    echo "amcl_pose_ok try=$i"; break
  fi
  sleep 2
done
echo "nodes:"; ros2 node list 2>/dev/null | grep -E "amcl|controller_server|bt_navigator"

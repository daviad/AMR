#!/usr/bin/env bash
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash
sleep 45
echo "---NODES---"
ros2 node list 2>/dev/null | grep -E 'controller_server|planner_server|amcl|map_server|bt_navigator'
echo "---MAP---"
timeout 15 ros2 topic echo /map --once --field info 2>&1 | head -10
echo "---AMCL---"
timeout 8 ros2 topic echo /amcl_pose --once --field pose.pose.position 2>&1 | head -8
echo "---GATEWAY8080---"
timeout 4 curl -s http://127.0.0.1:8080/api/v1/map/meta 2>&1 | head -c 300
echo
echo "---GATEWAY_RUNNING---"
pgrep -af 'gateway' | grep -v pgrep | head -3
echo "---NEWMAP_MD5---"
md5sum /home/dxw/amr/amr_sim_ws/src/amr_nav/maps/indoor.pgm

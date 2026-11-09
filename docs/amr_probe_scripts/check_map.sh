#!/usr/bin/env bash
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash
echo "---TOPICS---"
ros2 topic list 2>/dev/null | grep -E '^/scan$|^/map$|^/odom$|^/gz_truth$'
echo "---SCAN_HZ---"
timeout 8 ros2 topic hz /scan 2>&1 | tail -3
echo "---MAP_INFO---"
timeout 15 ros2 topic echo /map --once --field info 2>&1 | head -12
echo "---CARTO_LOG---"
grep -iE 'cartographer|trajectory|occupancy|error|fatal' /tmp/amr_probe/mapping.log | tail -15

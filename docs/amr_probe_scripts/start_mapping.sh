#!/usr/bin/env bash
set -e
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash
cd /home/dxw/amr/amr_sim_ws
exec ros2 launch amr_slam mapping.launch.py

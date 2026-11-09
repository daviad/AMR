#!/usr/bin/env bash
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash
ros2 run amr_slam save_map indoor 15.0

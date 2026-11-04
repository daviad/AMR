"""一键建图：仿真（gz sim + bridge）+ Cartographer 2D SLAM

不启动 Nav2 / map_server：建图阶段由 Cartographer 独占发布 /map，避免与
map_server 的静态地图冲突。建图完成后用 `ros2 run amr_slam save_map` 存图。

用法：
  ros2 launch amr_slam mapping.launch.py                    # headless
  ros2 launch amr_slam mapping.launch.py headless:=false    # 带 GUI 观察建图
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (DeclareLaunchArgument, IncludeLaunchDescription,
                            TimerAction)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    gz_share = get_package_share_directory('amr_gazebo')
    slam_share = get_package_share_directory('amr_slam')

    use_sim_time = LaunchConfiguration('use_sim_time')
    headless = LaunchConfiguration('headless')

    declare_args = [
        DeclareLaunchArgument('use_sim_time', default_value='true',
                              description='使用仿真时间'),
        DeclareLaunchArgument('headless', default_value='true',
                              description='无 GUI 模式（gz sim -s 仅服务端）'),
        DeclareLaunchArgument('slam_start_delay', default_value='5.0',
                              description='延时启动 Cartographer，等 /scan 与 TF 就绪'),
    ]

    # 仿真底座：gz sim + robot_state_publisher + spawn + ros_gz_bridge
    sim = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(gz_share, 'launch', 'sim_bringup.launch.py')),
        launch_arguments={'use_sim_time': use_sim_time,
                          'headless': headless}.items(),
    )

    # /cmd_vel 超时看门狗：gz DiffDrive 会锁存最后一条非零指令（实测松键后仍
    # 持续转动、/odom 漂移数十米），0.5s 无新指令补零速。建图阶段同样需要。
    cmd_vel_watchdog = Node(
        package='amr_inspection',
        executable='cmd_vel_watchdog',
        name='cmd_vel_watchdog',
        output='screen',
        parameters=[{'timeout_sec': 0.5}],
    )

    # Cartographer：延时启动，避免 /scan、/odom、TF 尚未就绪导致轨迹初始化失败
    slam = TimerAction(
        period=LaunchConfiguration('slam_start_delay'),
        actions=[
            IncludeLaunchDescription(
                PythonLaunchDescriptionSource(
                    os.path.join(slam_share, 'launch', 'cartographer.launch.py')),
                launch_arguments={'use_sim_time': use_sim_time}.items(),
            ),
        ],
    )

    return LaunchDescription(declare_args + [sim, cmd_vel_watchdog, slam])

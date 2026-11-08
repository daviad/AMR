"""仿真一键启动：gz sim + robot_state_publisher + spawn + ros_gz_bridge"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition, UnlessCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import Command, LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    # 用 ament_index 拼绝对路径（URDF 中禁用 $(find pkg)）
    desc_share = get_package_share_directory('amr_description')
    gz_share = get_package_share_directory('amr_gazebo')
    ros_gz_sim_share = get_package_share_directory('ros_gz_sim')
    xacro_file = os.path.join(desc_share, 'urdf', 'amr_robot.xacro')
    world_file = os.path.join(gz_share, 'worlds', 'indoor.world')
    bridge_yaml = os.path.join(gz_share, 'config', 'bridge_topics.yaml')
    gz_sim_launch = os.path.join(ros_gz_sim_share, 'launch', 'gz_sim.launch.py')

    use_sim_time = LaunchConfiguration('use_sim_time')
    headless = LaunchConfiguration('headless')

    declare_args = [
        DeclareLaunchArgument('use_sim_time', default_value='true',
                              description='使用仿真时间'),
        DeclareLaunchArgument('headless', default_value='true',
                              description='无 GUI 模式（gz sim -s 仅服务端）'),
        DeclareLaunchArgument('x', default_value='0.0'),
        DeclareLaunchArgument('y', default_value='0.0'),
        DeclareLaunchArgument('z', default_value='0.01',
                              description='出生高度：URDF 根帧已改为 base_footprint（落地面 z=0），'
                                          '轮底在模型 z=0，因此只需离地 1 cm 避免初始穿模'),
    ]

    # 机器人描述（xacro 展开）
    robot_description = {'robot_description': Command(['xacro ', xacro_file])}

    # gz sim：headless 用 -s 仅服务端；否则带 GUI（本机 GUI 库损坏时保持 headless）
    gz_sim_headless = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(gz_sim_launch),
        launch_arguments={'gz_args': ['-r -s ', world_file]}.items(),
        condition=IfCondition(headless),
    )
    gz_sim_gui = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(gz_sim_launch),
        launch_arguments={'gz_args': ['-r ', world_file]}.items(),
        condition=UnlessCondition(headless),
    )

    # robot_state_publisher：robot_description 走 parameters
    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        output='screen',
        parameters=[robot_description, {'use_sim_time': use_sim_time}],
    )

    # 把机器人 spawn 进 gz（从 /robot_description 话题读取）
    spawn = Node(
        package='ros_gz_sim',
        executable='create',
        output='screen',
        arguments=[
            '-topic', 'robot_description',
            '-name', 'amr_robot',
            '-x', LaunchConfiguration('x'),
            '-y', LaunchConfiguration('y'),
            '-z', LaunchConfiguration('z'),
        ],
    )

    # ros_gz_bridge：按 bridge_topics.yaml 桥接
    bridge = Node(
        package='ros_gz_bridge',
        executable='parameter_bridge',
        output='screen',
        parameters=[{'config_file': bridge_yaml}],
    )

    return LaunchDescription(declare_args + [
        gz_sim_headless,
        gz_sim_gui,
        rsp,
        spawn,
        bridge,
    ])

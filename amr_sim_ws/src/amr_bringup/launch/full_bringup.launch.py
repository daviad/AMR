"""一键启动全链路：
gz sim + ros_gz_bridge + Nav2 + inspection_node + rosbridge + mqtt_client
+ MediaMTX(WebRTC) + GStreamer 虚拟摄像头 + mission_bridge（Nav2 Action 语义桥）

注意：mosquitto broker 需先行启动（mosquitto -c <amr_comm>/config/mosquitto.conf）

视频链路（默认）：
  Gazebo /camera/image_raw -> GStreamer(gst_video_source) -> RTSP
  -> MediaMTX -> WebRTC WHEP(:8889) -> Flutter App
  /camera/image_raw/compressed 仅保留给"拍照"按需取单帧。
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (DeclareLaunchArgument, ExecuteProcess,
                            IncludeLaunchDescription, TimerAction)
from launch.conditions import IfCondition, UnlessCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    gz_share = get_package_share_directory('amr_gazebo')
    nav_share = get_package_share_directory('amr_nav')
    comm_share = get_package_share_directory('amr_comm')

    declare_args = [
        DeclareLaunchArgument('use_sim_time', default_value='true'),
        DeclareLaunchArgument('headless', default_value='true'),
        DeclareLaunchArgument(
            'map',
            default_value=os.path.join(nav_share, 'maps', 'indoor.yaml')),
        DeclareLaunchArgument('video_source', default_value='gazebo',
                              description='gazebo | test'),
        DeclareLaunchArgument('use_legacy_video', default_value='false',
                              description='true 时改用旧的 ffmpeg RTSP 推流'),
        DeclareLaunchArgument('trace_log_path',
                              default_value='/tmp/amr_trace.jsonl'),
    ]

    use_sim_time = LaunchConfiguration('use_sim_time')
    headless = LaunchConfiguration('headless')
    map_file = LaunchConfiguration('map')
    video_source = LaunchConfiguration('video_source')
    use_legacy_video = LaunchConfiguration('use_legacy_video')
    trace_log = LaunchConfiguration('trace_log_path')

    # 1. 仿真（gz sim + rsp + spawn + bridge）
    sim = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(gz_share, 'launch', 'sim_bringup.launch.py')),
        launch_arguments={'use_sim_time': use_sim_time,
                          'headless': headless}.items(),
    )

    # 1. /cmd_vel 超时看门狗：gz DiffDrive 锁存最后一条非零指令，
    #    0.5s 无新指令补零速，避免松键后持续转动 / 撞墙后轮子空转（/odom 漂移）
    cmd_vel_watchdog = Node(
        package='amr_inspection',
        executable='cmd_vel_watchdog',
        name='cmd_vel_watchdog',
        output='screen',
        # 计时用墙上时钟：仿真时钟暂停时看门狗仍需工作
        parameters=[{'timeout_sec': 0.5}],
    )

    # 2. Nav2（延时 10s 等 gz/bridge 就绪）
    nav2 = TimerAction(period=10.0, actions=[
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(nav_share, 'launch', 'nav_bringup.launch.py')),
            launch_arguments={'map': map_file,
                              'use_sim_time': use_sim_time}.items(),
        ),
    ])

    # 3. 巡检业务节点（延时 12s 等 Nav2 action 起来）
    inspection = TimerAction(period=12.0, actions=[
        Node(package='amr_inspection',
             executable='inspection_node',
             name='inspection_node',
             output='screen',
             parameters=[{'use_sim_time': use_sim_time}]),
    ])

    # 4. rosbridge（延时 5s）
    rosbridge = TimerAction(period=5.0, actions=[
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(comm_share, 'launch', 'rosbridge.launch.py'))),
    ])

    # 5. MQTT 桥（延时 5s，mosquitto 需已启动）
    mqtt_bridge = TimerAction(period=5.0, actions=[
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(comm_share, 'launch', 'mqtt_bridge.launch.py'))),
    ])

    # 6. 业务指令桥：MQTT -> Nav2 Action（ACK/Feedback/Result/取消/幂等）
    mission_bridge = TimerAction(period=6.0, actions=[
        Node(package='amr_comm',
             executable='mission_bridge.py',
             name='mission_bridge',
             output='screen',
             parameters=[{
                 'use_sim_time': use_sim_time,
                 'trace_log_path': trace_log,
                 'feedback_period_sec': 1.0,
                 'heartbeat_feedback': True,
             }]),
    ])

    # 7. 图像压缩中转（延时 5s）：只服务"拍照"按需取单帧，不再参与预览
    image_repub = TimerAction(period=5.0, actions=[
        Node(package='image_transport',
             executable='republish',
             name='image_republisher',
             output='screen',
             parameters=[{'in_transport': 'raw',
                          'out_transport': 'compressed',
                          'use_sim_time': use_sim_time}],
             remappings=[('in', '/camera/image_raw'),
                         ('out/compressed', '/camera/image_raw/compressed')]),
    ])

    # 8. mediamtx（RTSP + WebRTC WHEP + HLS），随仿真启动
    mediamtx_bin = os.path.expanduser('~/bin/mediamtx')
    mediamtx_cfg = os.path.join(gz_share, 'config', 'mediamtx.yml')
    mediamtx = ExecuteProcess(
        cmd=[mediamtx_bin, mediamtx_cfg],
        name='mediamtx',
        output='screen',
    )

    # 9. GStreamer 虚拟摄像头（延时 8s，等摄像头有数据 & MediaMTX 就绪）
    gst_local_lib = os.path.expanduser(
        '~/.local/gstreamer/usr/lib/x86_64-linux-gnu')
    gst_lib_path = gst_local_lib
    if os.environ.get('LD_LIBRARY_PATH'):
        gst_lib_path = gst_lib_path + ':' + os.environ['LD_LIBRARY_PATH']
    gst_video = TimerAction(period=8.0, actions=[
        Node(package='amr_gazebo',
             executable='gst_video_source.py',
             name='gst_video_source',
             output='screen',
             condition=UnlessCondition(use_legacy_video),
             additional_env={'LD_LIBRARY_PATH': gst_lib_path},
             parameters=[{
                 # 视频指标用墙上时钟，避免 /clock 跳变污染 PTS
                 'use_sim_time': False,
                 'source': video_source,
                 'image_topic': '/camera/image_raw',
                 'fps': 5.0,
                 'main_width': 320,
                 'main_height': 240,
                 'low_width': 160,
                 'low_height': 120,
                 'main_bitrate_kbps': 700,
                 'low_bitrate_kbps': 220,
                 'rtsp_main_url': 'rtsp://127.0.0.1:18554/camera',
                 'rtsp_low_url': 'rtsp://127.0.0.1:18554/camera_low',
                 'overlay_clock': True,
             }]),
    ])

    # 10. 旧 ffmpeg 推流作为 fallback（use_legacy_video:=true）
    legacy_rtsp = TimerAction(period=8.0, actions=[
        Node(package='amr_gazebo',
             executable='rtsp_publisher.py',
             name='rtsp_publisher',
             output='screen',
             condition=IfCondition(use_legacy_video),
             parameters=[{'use_sim_time': use_sim_time,
                          'rtsp_url': 'rtsp://localhost:18554/camera',
                          'fps': 5.0}]),
    ])

    return LaunchDescription(declare_args + [
        cmd_vel_watchdog,
        sim,
        nav2,
        inspection,
        rosbridge,
        mqtt_bridge,
        mission_bridge,
        image_repub,
        mediamtx,
        gst_video,
        legacy_rtsp,
    ])

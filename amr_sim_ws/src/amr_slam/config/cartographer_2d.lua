-- Cartographer 2D 配置：激光 + IMU + 轮式里程计
-- tracking_frame 用 imu_link（use_imu_data=true 时要求 tracking_frame 对应 IMU 帧）
include "map_builder.lua"
include "trajectory_builder.lua"

options = {
  map_builder = MAP_BUILDER,
  trajectory_builder = TRAJECTORY_BUILDER,
  map_frame = "map",
  tracking_frame = "imu_link",
  published_frame = "odom",
  odom_frame = "odom",
  provide_odom_frame = false,
  publish_frame_projected_to_2d = true,
  -- 使用轮式里程计作为先验（P1）。
  -- 前提：odom 的两个缺陷已修复——(1) DiffDrive 锁存最后一条非零指令，
  -- 已加 cmd_vel 看门狗；(2) 前脚轮摩擦导致原地旋转只有 ~40% 实际转角，
  -- 已把 front_caster_link 的 mu1/mu2 置 0。修复后 odom/真值偏航比 >0.95。
  -- 关掉 odom 时 scan matching 在长直墙方向会几何退化，实测 x 向漂移 34m。
  use_odometry = true,
  use_nav_sat = false,
  use_landmarks = false,
  num_laser_scans = 1,
  num_multi_echo_laser_scans = 0,
  num_subdivisions_per_laser_scan = 1,
  num_point_clouds = 0,
  lookup_transform_timeout_sec = 0.2,
  submap_publish_period_sec = 0.3,
  pose_publish_period_sec = 5e-2,  -- 20Hz（原值 5e-3=200Hz 会让 /tf 飙到 ~170Hz，导致 teleop 卡顿）
  trajectory_publish_period_sec = 30e-3,
  rangefinder_sampling_ratio = 1.,
  odometry_sampling_ratio = 1.,
  fixed_frame_pose_sampling_ratio = 1.,
  imu_sampling_ratio = 1.,
  landmarks_sampling_ratio = 1.,
}

MAP_BUILDER.use_trajectory_builder_2d = true

TRAJECTORY_BUILDER_2D.min_range = 0.12
TRAJECTORY_BUILDER_2D.max_range = 12.0
TRAJECTORY_BUILDER_2D.missing_data_ray_length = 5.0
TRAJECTORY_BUILDER_2D.use_imu_data = true
TRAJECTORY_BUILDER_2D.use_online_correlative_scan_matching = true
-- 搜索窗口：真实机器人轮子打滑/撞墙时里程计可能偏 0.2~0.3m，
-- 窗口需覆盖该偏差 scan matching 才能纠正。过大会增加计算量并可能误匹配。
TRAJECTORY_BUILDER_2D.real_time_correlative_scan_matcher.linear_search_window = 0.30
TRAJECTORY_BUILDER_2D.real_time_correlative_scan_matcher.angular_search_window = math.rad(20.)

POSE_GRAPH.optimization_problem.huber_scale = 1e2
POSE_GRAPH.optimize_every_n_nodes = 35  -- A/B 试验：20 实测更差（位姿误差 0.128→0.784m），已回滚
POSE_GRAPH.constraint_builder.min_score = 0.55  -- 与上游默认一致（原 0.65 过严，回环难以成立）

return options

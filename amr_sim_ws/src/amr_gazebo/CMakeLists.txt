cmake_minimum_required(VERSION 3.8)
project(amr_gazebo)

find_package(ament_cmake REQUIRED)

install(DIRECTORY launch worlds config
  DESTINATION share/${PROJECT_NAME}
)

install(PROGRAMS
  scripts/rtsp_publisher.py
  scripts/gst_video_source.py
  DESTINATION lib/${PROJECT_NAME}
)

ament_package()

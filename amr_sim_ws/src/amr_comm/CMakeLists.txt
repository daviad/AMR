cmake_minimum_required(VERSION 3.8)
project(amr_comm)

find_package(ament_cmake REQUIRED)

install(DIRECTORY launch config
  DESTINATION share/${PROJECT_NAME}
)

install(PROGRAMS
  scripts/mission_bridge.py
  DESTINATION lib/${PROJECT_NAME}
)

ament_package()

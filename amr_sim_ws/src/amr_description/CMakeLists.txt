cmake_minimum_required(VERSION 3.8)
project(amr_description)

find_package(ament_cmake REQUIRED)

# 纯资源包：仅安装 urdf 目录
install(DIRECTORY urdf
  DESTINATION share/${PROJECT_NAME}
)

ament_package()

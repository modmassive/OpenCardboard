cmake_minimum_required(VERSION 3.15)
project(driver_opencardboard CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# OpenVR headers are cloned next to this folder by the CI workflow (../openvr)
if(NOT OPENVR_DIR)
  set(OPENVR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../openvr")
endif()

add_library(driver_opencardboard SHARED src/driver.cpp)
target_include_directories(driver_opencardboard PRIVATE "${OPENVR_DIR}/headers")
target_compile_definitions(driver_opencardboard PRIVATE _CRT_SECURE_NO_WARNINGS WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(driver_opencardboard PRIVATE ws2_32 d3d11 dxgi)

cmake_minimum_required(VERSION 3.5)

project(acid-breakout-vk)

cmake_policy(SET CMP0015 NEW)

find_package(glfw3 REQUIRED)

include_directories(external/wgpu/include)
link_directories(external/wgpu/bin)

add_subdirectory(external/glfw3webgpu glfw3webgpu)

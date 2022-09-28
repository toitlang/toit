# The following lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.5)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(toit)

target_link_libraries(${project_elf} "-L ${CMAKE_CURRENT_SOURCE_DIR}/../../build/${target}/lib")
target_link_libraries(${project_elf} "-Wl,--whole-archive -ltoit_vm -Wl,--no-whole-archive")

cmake_minimum_required(VERSION 3.27)

set(VCPKG_TRACE_FIND_PACKAGE ON)

project(my_project)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
  error("missing CMAKE_BUILD_TYPE, please use --preset")
endif()

add_compile_options(-Wall -Werror)
add_link_options(-fuse-ld=lld)

find_package(fmt CONFIG REQUIRED)
find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)
find_package(GTest CONFIG REQUIRED)

include(cmake/rules.cmake)

add_subdirectory(src)

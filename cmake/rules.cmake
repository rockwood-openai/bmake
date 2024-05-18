include(CMakeParseArguments)

# my_cc_library()
#
# CMake function to imitate a starlark-like cc_library rule.
#
# Parameters:
# NAME: name of target (see Note)
# HDRS: List of public header files for the library
# SRCS: List of source files (and private headers) for the library
# DEPS: List of other libraries to be linked in to the binary targets
# COPTS: List of private compile options
# DEFINES: List of public defines
# LINKOPTS: List of link options
#
# Note:
# By default, my_cc_library will always create a library named my_${NAME},
# and alias target my::${NAME}.  The my:: form should always be used.
# This is to reduce namespace pollution.
#
# my_cc_library(
#   NAME
#     awesome
#   HDRS
#     "a.h"
#   SRCS
#     "a.cc"
# )
# my_cc_library(
#   NAME
#     fantastic_lib
#   SRCS
#     "b.cc"
#   DEPS
#     my::awesome # not "awesome" !
# )
#
# my_cc_library(
#   NAME
#     main_lib
#   ...
#   DEPS
#     my::fantastic_lib
# )
#
function(my_cc_library)
  cmake_parse_arguments(MY_CC_LIB
    "" # options
    "NAME" # single value
    "HDRS;SRCS;COPTS;DEFINES;LINKOPTS;DEPS" # multi value 
    ${ARGN})

  set(_NAME "my_${MY_CC_LIB_NAME}")

  # Check if this is a header-only library
  set(MY_CC_SRCS "${MY_CC_LIB_SRCS}")
  list(FILTER MY_CC_SRCS EXCLUDE REGEX ".*\\.(h|inc)")
  if("${MY_CC_SRCS}" STREQUAL "")
    set(MY_CC_LIB_IS_INTERFACE 1)
  else()
    set(MY_CC_LIB_IS_INTERFACE 0)
  endif()

  if(NOT MY_CC_LIB_IS_INTERFACE)
    add_library(${_NAME} "")
    target_sources(${_NAME} PRIVATE ${MY_CC_LIB_SRCS} ${MY_CC_LIB_HDRS})
    # TODO: Determine how to limit header visibility
    # There are really 3 approaches:
    # - Symlink headers so that includes are limited (bazel does this), downside being some tooling is confused by symlinks
    # - Force include directory pattern . this basically puts the burden on the dev to isolate headers
    # - Use something like landlock LSM to sandbox headers via a wrapper and CXX_COMPILER_LAUNCHER
    target_compile_options(${_NAME}
      PRIVATE ${MY_CC_LIB_COPTS})
    target_link_libraries(${_NAME}
      PUBLIC ${MY_CC_LIB_DEPS}
      PRIVATE ${MY_CC_LIB_LINKOPTS})
    target_compile_definitions(${_NAME} PUBLIC ${MY_CC_LIB_DEFINES})
  else()
    # Generating header-only library
    add_library(${_NAME} INTERFACE)
    # TODO: Limit header visibility - see options above
    target_link_libraries(${_NAME}
      INTERFACE
      ${MY_CC_LIB_DEPS}
      ${MY_CC_LIB_LINKOPTS}
      )
    target_compile_definitions(${_NAME} INTERFACE ${MY_CC_LIB_DEFINES})
  endif()
  # main symbol exported
  add_library(my::${MY_CC_LIB_NAME} ALIAS ${_NAME})
endfunction()

find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)

# my_proto_library()
#
# CMake function to imitate a starlark-like cc_proto_library rule.
#
# Parameters:
# NAME: name of target (see Note)
# SRCS: List of proto files
# DEPS: List of other proto libraries that are required for import to work
# COPTS: List of private compile options
# DEFINES: List of public defines
# LINKOPTS: List of link options
# GRPC: If the gRPC protoc plugin should be used.
#
# my_proto_library(
#   NAME
#     foo
#   SRCS
#     "foo.proto"
# )
#
# my_cc_library(
#   NAME
#     awesome_lib
#   SRCS
#     "b.cc"
#   DEPS
#     my::foo
# )
#
function(my_proto_library)
  cmake_parse_arguments(MY_PROTO_LIB
    "GRPC" # options
    "NAME" # single value
    "SRCS;COPTS;DEFINES;LINKOPTS;DEPS" # multi value 
    ${ARGN})

  set(_NAME "my_protoc_generated_sources_${MY_PROTO_LIB_NAME}")

  # TODO: Add import dirs for dependencies, right now this assumes all protos
  # are in a single directory
  protobuf_generate(
    PROTOS ${MY_PROTO_LIB_SRCS}
    LANGUAGE cpp
    GENERATE_EXTENSIONS .pb.h .pb.cc
    OUT_VAR _generated_pb
  )
  set(_extra_deps "")
  if (MY_PROTO_LIB_GRPC)
    protobuf_generate(
      PROTOS ${MY_PROTO_LIB_SRCS}
      LANGUAGE grpc
      GENERATE_EXTENSIONS .grpc.pb.h .grpc.pb.cc
      PLUGIN "protoc-gen-grpc=\$<TARGET_FILE:gRPC::grpc_cpp_plugin>"
      OUT_VAR _generated_grpc_pb
    )
    set(_generated_pb ${_generated_pb} ${_generated_grpc_pb})
    set(_extra_deps gRPC::grpc gRPC::grpc++ gRPC::grpc++_reflection)
  endif()
  set_source_files_properties(
    ${_generated_pb}
    PROPERTIES SKIP_LINTING ON
  )
  set(GENERATED_HDRS "${_generated_pb}")
  list(FILTER GENERATED_HDRS INCLUDE REGEX ".*\\.(h|inc)")
  set(GENERATED_SRCS "${_generated_pb}")
  list(FILTER GENERATED_SRCS EXCLUDE REGEX ".*\\.(h|inc)")
  my_cc_library(
    NAME ${MY_PROTO_LIB_NAME}
    HDRS ${GENERATED_HDRS}
    SRCS ${GENERATED_SRCS}
    DEPS 
      ${MY_PROTO_LIB_DEPS}
      protobuf::libprotobuf
      ${_extra_deps}
    COPTS ${MY_PROTO_LIB_COPTS}
    DEFINES ${MY_PROTO_LIB_DEFINES}
    LINKOPTS ${MY_PROTO_LIB_LINKOPTS}
  )
endfunction()

find_package(GTest REQUIRED)

# my_cc_test()
#
# CMake function to imitate a starlark-like cc_test rule.
#
# Parameters:
# NAME: name of target (see Usage below)
# SRCS: List of source files for the binary
# DEPS: List of other libraries to be linked in to the binary targets
# COPTS: List of private compile options
# DEFINES: List of public defines
# LINKOPTS: List of link options
#
# Note:
# By default, my_cc_test will always create a binary named my_${NAME}.
# This will also add it to ctest list as my_${NAME}.
#
# Usage:
# my_cc_library(
#   NAME
#     awesome
#   HDRS
#     "a.h"
#   SRCS
#     "a.cc"
# )
#
# my_cc_test(
#   NAME
#     awesome_test
#   SRCS
#     "awesome_test.cc"
#   DEPS
#     my::awesome
#     GTest::gmock
#     GTest::gtest_main
# )
function(my_cc_test)
  cmake_parse_arguments(MY_CC_TEST
    ""
    "NAME"
    "SRCS;COPTS;DEFINES;LINKOPTS;DEPS"
    ${ARGN}
  )

  set(_NAME "my_${MY_CC_TEST_NAME}")

  add_executable(${_NAME} "")
  target_sources(${_NAME} PRIVATE ${MY_CC_TEST_SRCS})

  target_compile_definitions(${_NAME}
    PUBLIC ${MY_CC_TEST_DEFINES})
  target_compile_options(${_NAME}
    PRIVATE ${MY_CC_TEST_COPTS})

  target_link_libraries(${_NAME}
    PUBLIC ${MY_CC_TEST_DEPS}
    PRIVATE ${MY_CC_TEST_LINKOPTS})
  gtest_discover_tests(${_NAME})
endfunction()

# my_cc_binary()
#
# CMake function to imitate a starlark-like cc_binary rule.
#
# Parameters:
# NAME: name of target (see Usage below)
# SRCS: List of source files for the binary
# DEPS: List of other libraries to be linked in to the binary targets
# COPTS: List of private compile options
# DEFINES: List of public defines
# LINKOPTS: List of link options
# DISABLE_INSTALL: Disable installation of the binary
# DESTINATION: Subdirectory to install the binary (in `ninja install`)
#
# Note:
# By default, my_cc_binary will always create a binary named ${NAME}.
# Additionally, it's listed as a target to install, which can be changed 
# with the DISABLE_INSTALL option.
#
# Usage:
# my_cc_library(
#   NAME
#     awesome
#   HDRS
#     "a.h"
#   SRCS
#     "a.cc"
# )
#
# my_cc_binary(
#   NAME
#     awesome_binary
#   SRCS
#     "main.cc"
#   DEPS
#     my::awesome
# )
function(my_cc_binary)
  cmake_parse_arguments(MY_CC_BINARY
    "DISABLE_INSTALL"
    "NAME"
    "SRCS;COPTS;DEFINES;LINKOPTS;DEPS;DESTINATION"
    ${ARGN}
  )

  add_executable(${MY_CC_BINARY_NAME} "")
  target_sources(${MY_CC_BINARY_NAME} PRIVATE ${MY_CC_BINARY_SRCS})

  target_compile_definitions(
    ${MY_CC_BINARY_NAME}
    PUBLIC ${MY_CC_BINARY_DEFINES}
  )
  target_compile_options(
    ${MY_CC_BINARY_NAME}
    PRIVATE ${MY_CC_BINARY_COPTS}
  )

  target_link_libraries(
    ${MY_CC_BINARY_NAME}
    PUBLIC ${MY_CC_BINARY_DEPS}
    PRIVATE ${MY_CC_BINARY_LINKOPTS}
  )
  if(NOT MY_CC_BINARY_DISABLE_INSTALL)
    install(
      TARGETS ${MY_CC_BINARY_NAME}
      DESTINATION ${MY_CC_BINARY_DESTINATION}
    )
  endif()
endfunction()

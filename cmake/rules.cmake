include(CMakeParseArguments)

define_property(
  TARGET
  PROPERTY landlock_public_headers
  BRIEF_DOCS "A list of public headers for a target, can be used for strict sandboxing of clang"
)

define_property(
  TARGET
  PROPERTY landlock_proto_files
  BRIEF_DOCS "A list of .proto files that were used to generate this target, can be used for strict sandboxing of protoc"
)

# landlock_cc_library()
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
# By default, landlock_cc_library will always create a library named my_${NAME},
# and alias target my::${NAME}.  The my:: form should always be used.
# This is to reduce namespace pollution.
#
# landlock_cc_library(
#   NAME
#     awesome
#   HDRS
#     "awesome.h"
#   SRCS
#     "awesome.cc"
# )
# landlock_cc_library(
#   NAME
#     fantastic
#   SRCS
#     "fantastic.cc"
#   DEPS
#     my::awesome # not "awesome" !
# )
#
# landlock_cc_binary(
#   NAME
#     main
#   ...
#   DEPS
#     my::fantastic
# )
#
function(landlock_cc_library)
  cmake_parse_arguments(LANDLOCK_CC_LIB
    "" # options
    "NAME" # single value
    "HDRS;SRCS;COPTS;DEFINES;LINKOPTS;DEPS" # multi value 
    ${ARGN})

  set(_NAME "landlock_${LANDLOCK_CC_LIB_NAME}")

  # Check if this is a header-only library
  set(LANDLOCK_CC_SRCS "${LANDLOCK_CC_LIB_SRCS}")
  list(FILTER LANDLOCK_CC_SRCS EXCLUDE REGEX ".*\\.(h|inc)")
  if("${LANDLOCK_CC_SRCS}" STREQUAL "")
    set(LANDLOCK_CC_LIB_IS_INTERFACE 1)
  else()
    set(LANDLOCK_CC_LIB_IS_INTERFACE 0)
  endif()

  if(NOT LANDLOCK_CC_LIB_IS_INTERFACE)
    add_library(${_NAME} "")
    target_sources(${_NAME} PRIVATE ${LANDLOCK_CC_LIB_SRCS} ${LANDLOCK_CC_LIB_HDRS})
    # TODO: Determine how to limit header visibility
    # There are really 3 approaches:
    # - Symlink headers so that includes are limited (bazel does this), downside being some tooling is confused by symlinks
    # - Force include directory pattern . this basically puts the burden on the dev to isolate headers
    # - Use something like landlock LSM to sandbox headers via a wrapper and CXX_COMPILER_LAUNCHER
    target_compile_options(${_NAME}
      PRIVATE ${LANDLOCK_CC_LIB_COPTS})
    target_link_libraries(${_NAME}
      PUBLIC ${LANDLOCK_CC_LIB_DEPS}
      PRIVATE ${LANDLOCK_CC_LIB_LINKOPTS})
    target_compile_definitions(${_NAME} PUBLIC ${LANDLOCK_CC_LIB_DEFINES})
  else()
    # Generating header-only library
    add_library(${_NAME} INTERFACE)
    # TODO: Limit header visibility - see options above
    target_link_libraries(${_NAME}
      INTERFACE
      ${LANDLOCK_CC_LIB_DEPS}
      ${LANDLOCK_CC_LIB_LINKOPTS}
      )
    target_compile_definitions(${_NAME} INTERFACE ${LANDLOCK_CC_LIB_DEFINES})
  endif()

  set(LANDLOCK_CC_HDRS "${LANDLOCK_CC_HDRS}")
  # Use absolute paths
  list(TRANSFORM LANDLOCK_CC_SRCS PREPEND ${CMAKE_CURRENT_SOURCE_DIR}/)
  # TODO(rockwood): add dependencies
  set_target_properties(${_NAME} PROPERTIES landlock_public_headers "${LANDLOCK_CC_LIB_HDRS}")
  # main symbol exported
  add_library(my::${LANDLOCK_CC_LIB_NAME} ALIAS ${_NAME})
endfunction()

find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)

# landlock_proto_library()
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
# landlock_proto_library(
#   NAME
#     foo
#   SRCS
#     "foo.proto"
# )
#
# landlock_cc_library(
#   NAME
#     awesome_lib
#   SRCS
#     "b.cc"
#   DEPS
#     my::foo
# )
#
function(landlock_proto_library)
  cmake_parse_arguments(LANDLOCK_PROTO_LIB
    "GRPC" # options
    "NAME" # single value
    "SRCS;COPTS;DEFINES;LINKOPTS;DEPS" # multi value 
    ${ARGN})

  set(_NAME "landlock_protoc_generated_sources_${LANDLOCK_PROTO_LIB_NAME}")

  # TODO: Add import dirs for dependencies, right now this assumes all protos
  # are in a single directory
  protobuf_generate(
    PROTOS ${LANDLOCK_PROTO_LIB_SRCS}
    LANGUAGE cpp
    GENERATE_EXTENSIONS .pb.h .pb.cc
    OUT_VAR _generated_pb
  )
  set(_extra_deps "")
  if (LANDLOCK_PROTO_LIB_GRPC)
    protobuf_generate(
      PROTOS ${LANDLOCK_PROTO_LIB_SRCS}
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
  landlock_cc_library(
    NAME ${LANDLOCK_PROTO_LIB_NAME}
    HDRS ${GENERATED_HDRS}
    SRCS ${GENERATED_SRCS}
    DEPS 
      ${LANDLOCK_PROTO_LIB_DEPS}
      protobuf::libprotobuf
      ${_extra_deps}
    COPTS ${LANDLOCK_PROTO_LIB_COPTS}
    DEFINES ${LANDLOCK_PROTO_LIB_DEFINES}
    LINKOPTS ${LANDLOCK_PROTO_LIB_LINKOPTS}
  )
  set(LANDLOCK_PROTOS "${LANDLOCK_PROTO_LIB_SRCS}")
  # Use absolute paths
  list(TRANSFORM LANDLOCK_PROTOS PREPEND ${CMAKE_CURRENT_SOURCE_DIR}/)
  # TODO(rockwood): add dependencies
  set_target_properties(my::${LANDLOCK_PROTO_LIB_NAME} PROPERTIES landlock_proto_files "${LANDLOCK_PROTOS}")
endfunction()

find_package(GTest REQUIRED)

# landlock_cc_test()
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
# By default, landlock_cc_test will always create a binary named my_${NAME}.
# This will also add it to ctest list as landlock_${NAME}.
#
# Usage:
# landlock_cc_library(
#   NAME
#     awesome
#   HDRS
#     "a.h"
#   SRCS
#     "a.cc"
# )
#
# landlock_cc_test(
#   NAME
#     awesome_test
#   SRCS
#     "awesome_test.cc"
#   DEPS
#     my::awesome
#     GTest::gmock
#     GTest::gtest_main
# )
function(landlock_cc_test)
  cmake_parse_arguments(LANDLOCK_CC_TEST
    ""
    "NAME"
    "SRCS;COPTS;DEFINES;LINKOPTS;DEPS"
    ${ARGN}
  )

  set(_NAME "landlock_${LANDLOCK_CC_TEST_NAME}")

  add_executable(${_NAME} "")
  target_sources(${_NAME} PRIVATE ${LANDLOCK_CC_TEST_SRCS})

  target_compile_definitions(${_NAME}
    PUBLIC ${LANDLOCK_CC_TEST_DEFINES})
  target_compile_options(${_NAME}
    PRIVATE ${LANDLOCK_CC_TEST_COPTS})

  target_link_libraries(${_NAME}
    PUBLIC ${LANDLOCK_CC_TEST_DEPS}
    PRIVATE ${LANDLOCK_CC_TEST_LINKOPTS})
  gtest_discover_tests(${_NAME})
endfunction()

# landlock_cc_binary()
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
# By default, landlock_cc_binary will always create a binary named ${NAME}.
# Additionally, it's listed as a target to install, which can be changed 
# with the DISABLE_INSTALL option.
#
# Usage:
# landlock_cc_library(
#   NAME
#     awesome
#   HDRS
#     "a.h"
#   SRCS
#     "a.cc"
# )
#
# landlock_cc_binary(
#   NAME
#     awesome_binary
#   SRCS
#     "main.cc"
#   DEPS
#     my::awesome
# )
function(landlock_cc_binary)
  cmake_parse_arguments(LANDLOCK_CC_BINARY
    "DISABLE_INSTALL"
    "NAME"
    "SRCS;COPTS;DEFINES;LINKOPTS;DEPS;DESTINATION"
    ${ARGN}
  )

  add_executable(${LANDLOCK_CC_BINARY_NAME} "")
  target_sources(${LANDLOCK_CC_BINARY_NAME} PRIVATE ${LANDLOCK_CC_BINARY_SRCS})

  target_compile_definitions(
    ${LANDLOCK_CC_BINARY_NAME}
    PUBLIC ${LANDLOCK_CC_BINARY_DEFINES}
  )
  target_compile_options(
    ${LANDLOCK_CC_BINARY_NAME}
    PRIVATE ${LANDLOCK_CC_BINARY_COPTS}
  )

  target_link_libraries(
    ${LANDLOCK_CC_BINARY_NAME}
    PUBLIC ${LANDLOCK_CC_BINARY_DEPS}
    PRIVATE ${LANDLOCK_CC_BINARY_LINKOPTS}
  )
  if(NOT LANDLOCK_CC_BINARY_DISABLE_INSTALL)
    install(
      TARGETS ${LANDLOCK_CC_BINARY_NAME}
      DESTINATION ${LANDLOCK_CC_BINARY_DESTINATION}
    )
  endif()
endfunction()

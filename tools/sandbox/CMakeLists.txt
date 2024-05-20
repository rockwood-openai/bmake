add_executable(sandbox_process_wrapper process_wrapper.cc)
target_link_libraries(sandbox_process_wrapper PUBLIC fmt::fmt absl::strings absl::cleanup)
add_executable(sandbox::process_wrapper ALIAS sandbox_process_wrapper)

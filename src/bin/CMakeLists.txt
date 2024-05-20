landlock_cc_binary(
  NAME cli
  SRCS main.cc
  DEPS
    fmt::fmt
    my::add
    my::slow_mul
)

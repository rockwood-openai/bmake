landlock_cc_library(
  NAME add
  HDRS add.h
  SRCS add.cc
)

landlock_cc_library(
  NAME mul
  HDRS mul.h
  SRCS mul.cc
)

landlock_cc_library(
  NAME slow_mul
  HDRS slow_mul.h
  SRCS slow_mul.cc
  DEPS my::add
)

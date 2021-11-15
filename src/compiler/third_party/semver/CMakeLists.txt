cmake_minimum_required(VERSION 3.0)

set(SEMVER_STATIC_LIB_NAME "semver" CACHE STRING "Base name of static library output")

project (semver C)

set(SRCS semver.c)

add_library(semver ${SRCS})

set_target_properties(semver
  PROPERTIES DEFINE_SYMBOL YAML_DECLARE_EXPORT
  )

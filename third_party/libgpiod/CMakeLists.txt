# Support Version in project
cmake_policy(SET CMP0048 NEW)
# All integrating projects to control the optiom values
cmake_policy(SET CMP0077 NEW)
# 3.11 for FetchContent, 3.13 for CMP0077 and 3.14 for FetchContent improvements
cmake_minimum_required(VERSION 3.14)

project(gpiod VERSION 2.1.3 LANGUAGES C CXX)
set(GPIOD_VERSION_STR "${PROJECT_VERSION}-${GPIOD_EXTRA_VERSION}")

include(FetchContent)
include(CheckSymbolExists)
include(CheckIncludeFile)
include(GNUInstallDirs)

# libgpiod c library dependencies:
check_symbol_exists(ioctl "sys/ioctl.h" HAVE_IOCTL)
# Enable _GNU_SOURCE in symbol exists checks - this is
# a setting handled by the check_symbol_exists macro
set(CMAKE_REQUIRED_DEFINITIONS -D_GNU_SOURCE)
check_symbol_exists(asprintf "stdio.h" HAVE_ASPRINTF)
check_symbol_exists(scandir "dirent.h" HAVE_SCANDIR)
check_symbol_exists(alphasort "dirent.h" HAVE_ALPHASORT)
check_symbol_exists(ppoll "signal.h;poll.h"  HAVE_PPOLL)
check_symbol_exists(realpath "limits.h;stdlib.h"  HAVE_REALPATH)
check_include_file(getopt.h HAVE_GETOPT_H)
check_include_file(sys/sysmacros.h  HAVE_SYS_MACROS_H)
check_include_file(linux/version.h  HAVE_LINUX_VERSION_H)
check_include_file(linux/const.h  HAVE_LINUX_CONST_H)
check_include_file(linux/ioctl.h  HAVE_LINUX_IOCTL_H)
check_include_file(linux/types.h  HAVE_LINUX_TYPES_H)
if(HAVE_IOCTL AND HAVE_ASPRINTF AND HAVE_SCANDIR AND HAVE_ALPHASORT AND HAVE_PPOLL AND HAVE_REALPATH AND HAVE_GETOPT_H
  AND HAVE_LINUX_CONST_H AND HAVE_LINUX_IOCTL_H AND HAVE_LINUX_TYPES_H)
  message(STATUS "Header and function check successfull")
else()
  message(SEND_ERROR "Missing headers or symbols - libgpiod will not compile")
endif()

add_library(gpiod
    lib/chip-info.c
    lib/chip.c
    lib/edge-event.c
    lib/info-event.c
    lib/internal.c
    lib/line-config.c
    lib/line-info.c
    lib/line-request.c
    lib/line-settings.c
    lib/misc.c
    lib/request-config.c)
target_compile_options(gpiod PRIVATE -Wall -Wextra -fvisibility=hidden)
target_compile_definitions(gpiod PRIVATE _GNU_SOURCE=1 GPIOD_VERSION_STR="${GPIOD_VERSION_STR}")
add_library(gpiod::gpiod ALIAS gpiod)
set_target_properties(gpiod PROPERTIES
  VERSION ${PROJECT_VERSION}
  SOVERSION ${PROJECT_VERSION_MAJOR}
  PUBLIC_HEADER include/gpiod.h
  )
target_include_directories(gpiod PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/include/>)

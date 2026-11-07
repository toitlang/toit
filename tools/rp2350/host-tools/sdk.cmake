# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

include(ExternalProject)

# Use a separate project so the VM's compiler flags, mbedTLS definitions and
# targets do not leak into picotool. Preserve the SDK's target ABI and sysroot.
set(rp2350_cache "${CMAKE_CURRENT_BINARY_DIR}/rp2350-host-tools-cache.cmake")
file(WRITE "${rp2350_cache}" "# Generated SDK host-tool configuration.\n")
foreach(variable
    CMAKE_C_COMPILER CMAKE_CXX_COMPILER
    CMAKE_C_COMPILER_TARGET CMAKE_CXX_COMPILER_TARGET
    CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN CMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN
    CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
    CMAKE_SYSROOT CMAKE_OSX_SYSROOT CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET
    CMAKE_C_FLAGS CMAKE_CXX_FLAGS CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS)
  if(variable MATCHES "_FLAGS$")
    # The cache retains the toolchain/user flags from before Toit appends
    # -fno-exceptions and its mbedTLS configuration to the directory variables.
    get_property(value CACHE ${variable} PROPERTY VALUE)
    if(variable STREQUAL "CMAKE_SHARED_LINKER_FLAGS")
      get_property(exe_flags CACHE CMAKE_EXE_LINKER_FLAGS PROPERTY VALUE)
      string(REGEX MATCH "-fuse-ld=[^ ]+" linker_selection "${exe_flags}")
      string(APPEND value " ${linker_selection}")
    endif()
  else()
    set(value "${${variable}}")
  endif()
  if(DEFINED ${variable})
    # The standalone project selects the appropriate runtime linkage.
    if(variable MATCHES "LINKER_FLAGS")
      string(REGEX REPLACE "(^| )-static( |$)" " " value "${value}")
    endif()
    file(APPEND "${rp2350_cache}" "set(${variable} [==[${value}]==] CACHE STRING \"\" FORCE)\n")
  endif()
endforeach()
if(TOIT_IS_CROSS)
  file(APPEND "${rp2350_cache}"
    "set(CMAKE_SYSTEM_NAME [==[${CMAKE_SYSTEM_NAME}]==] CACHE STRING \"\" FORCE)\n"
    "set(CMAKE_SYSTEM_PROCESSOR [==[${CMAKE_SYSTEM_PROCESSOR}]==] CACHE STRING \"\" FORCE)\n")
endif()

ExternalProject_Add(rp2350_host_tools
  SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}"
  BINARY_DIR "${CMAKE_BINARY_DIR}/rp2350-host-tools"
  CMAKE_ARGS
    -C "${rp2350_cache}"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/sdk"
    "-DPICO_SDK_PATH=${TOIT_SDK_SOURCE_DIR}/third_party/pico-sdk"
    "-DPICO_MBEDTLS_PATH=${TOIT_MBEDTLS_DIR}"
  BUILD_ALWAYS TRUE)
ExternalProject_Add_StepDependencies(rp2350_host_tools configure "${rp2350_cache}")
add_dependencies(build_tools rp2350_host_tools)

# The external project's install step stages files into the build-tree SDK.
# Include the same files in `make install` and release archives.
install(DIRECTORY "${CMAKE_BINARY_DIR}/sdk/lib/toit/bin/"
  DESTINATION lib/toit/bin USE_SOURCE_PERMISSIONS
  FILES_MATCHING PATTERN "picotool*" PATTERN "ota-upload*" PATTERN "libusb-1.0*")
install(DIRECTORY "${CMAKE_BINARY_DIR}/sdk/lib/toit/rp2350/"
  DESTINATION lib/toit/rp2350 USE_SOURCE_PERMISSIONS)

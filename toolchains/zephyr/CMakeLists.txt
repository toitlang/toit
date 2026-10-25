# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
cmake_minimum_required(VERSION 3.20...4.0)
list(APPEND BOARD_ROOT "${CMAKE_CURRENT_LIST_DIR}")
list(APPEND DTS_ROOT "${CMAKE_CURRENT_LIST_DIR}")
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(toit_zephyr C CXX)
target_sources(app PRIVATE fatal.c)
if (CONFIG_BT_HCI_HOST AND NOT CONFIG_BT_HOST_CRYPTO AND NOT CONFIG_BT_CTLR_CRYPTO)
  target_sources(app PRIVATE bluetooth_crypto.c)
endif()
option(TOIT_ZEPHYR_BUILD_VM "Build the Toit VM" ON)
if (NOT TOIT_ZEPHYR_BUILD_VM)
  set(TOIT_ZEPHYR_NATIVE_SOURCE "${CMAKE_CURRENT_LIST_DIR}/bringup.c" CACHE FILEPATH "Native probe source")
  set(TOIT_ZEPHYR_NATIVE_DEFINITIONS "" CACHE STRING "Native probe compile definitions")
  target_sources(app PRIVATE "${TOIT_ZEPHYR_NATIVE_SOURCE}")
  target_compile_definitions(app PRIVATE ${TOIT_ZEPHYR_NATIVE_DEFINITIONS})
endif()
target_sources_ifdef(CONFIG_SOC_NRF5340_CPUAPP app PRIVATE entropy_nrf5340.c)

if (TOIT_ZEPHYR_BUILD_VM)
  get_filename_component(TOIT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
  if (CONFIG_TOIT_PSA_CRYPTO)
    if (CONFIG_MBEDTLS)
      message(FATAL_ERROR "Toit PSA must use the custom provider, not Zephyr's Mbed TLS module")
    endif()
    # Zephyr's Bluetooth libraries and Toit must agree on the PSA ABI. Use
    # the vendored Toit headers and configuration for every translation unit.
    zephyr_include_directories(
      "${TOIT_ROOT}/third_party/esp-idf/components/mbedtls/mbedtls/include"
      "${TOIT_ROOT}/mbedtls/include"
      "${CMAKE_CURRENT_LIST_DIR}/include")
    zephyr_compile_definitions(MBEDTLS_CONFIG_FILE="${TOIT_ROOT}/mbedtls/include/zephyr_config.h")
  endif()
  set(TOIT_SYSTEM_NAME zephyr)
  set(TOIT_VM_LIBRARY_TYPE OBJECT)
  set(TOIT_MODEL "${BOARD}")
  set(TOIT_HOST "${TOIT_ROOT}/build/host/sdk/bin/toit" CACHE FILEPATH "Matching host compiler")
  set(TOIT_ZEPHYR_PROGRAM "${TOIT_ROOT}/tests/hw/nrf5340/vm-smoke.toit" CACHE FILEPATH "Bundled application source; empty for system only")
  set(TOIT_ZEPHYR_PROGRAM_ASSETS "" CACHE FILEPATH "Encoded assets for the bundled application")
  set(TOIT_ZEPHYR_BUNDLED_IMAGES "" CACHE STRING "Additional relocatable 32-bit images to bundle")
  add_compile_definitions(TOIT_ZEPHYR RAW _POSIX_C_SOURCE=200809L _DEFAULT_SOURCE)
  include_directories("${CMAKE_CURRENT_LIST_DIR}/include")
  add_subdirectory("${TOIT_ROOT}" toit EXCLUDE_FROM_ALL)
  foreach(target toit_vm mbedtls mbedcrypto mbedx509 everest p256m)
    target_link_libraries(${target} PRIVATE zephyr_interface)
    add_dependencies(${target} zephyr_generated_headers)
    set_property(TARGET ${target} PROPERTY C_STANDARD 11)
  endforeach()
  function(toit_compile_image name source assets)
    add_custom_command(OUTPUT "${name}.snapshot"
      COMMAND "${TOIT_HOST}" compile -s -o "${name}.snapshot"
        --dependency-file "${name}.d" --dependency-format ninja "${source}"
      DEPENDS "${TOIT_HOST}" "${source}"
      DEPFILE "${name}.d"
      VERBATIM)
    set(asset_args "")
    if (assets)
      list(APPEND asset_args --assets "${assets}")
    endif()
    add_custom_command(OUTPUT "${name}.image"
      COMMAND "${TOIT_HOST}" tool snapshot-to-image --format=binary -m32
        -o "${name}.image" ${asset_args} "${name}.snapshot"
      DEPENDS "${name}.snapshot" "${TOIT_HOST}" ${assets}
      VERBATIM)
  endfunction()
  toit_compile_image(boot "${TOIT_ROOT}/system/extensions/zephyr/boot.toit" "")
  set(bundled_images ${TOIT_ZEPHYR_BUNDLED_IMAGES})
  if (TOIT_ZEPHYR_PROGRAM)
    toit_compile_image(application "${TOIT_ZEPHYR_PROGRAM}" "${TOIT_ZEPHYR_PROGRAM_ASSETS}")
    list(PREPEND bundled_images "application.image")
  endif()
  add_custom_command(OUTPUT "boot.S"
    COMMAND "${TOIT_HOST}" run "${TOIT_ROOT}/tools/zephyr/image-to-assembly.toit" -- boot.image boot.S ${bundled_images}
    DEPENDS "boot.image" ${bundled_images} "${TOIT_HOST}"
      "${TOIT_ROOT}/tools/zephyr/image-to-assembly.toit"
    VERBATIM)

  target_sources(app PRIVATE main.cc atomics.c "${CMAKE_CURRENT_BINARY_DIR}/boot.S")
  set(TOIT_ZEPHYR_STARTUP_TEST "" CACHE FILEPATH "Optional native qualification test after VM platform initialization")
  if (TOIT_ZEPHYR_STARTUP_TEST)
    target_sources(app PRIVATE "${TOIT_ZEPHYR_STARTUP_TEST}")
    target_compile_definitions(app PRIVATE TOIT_ZEPHYR_STARTUP_TEST=1)
  endif()
  zephyr_linker_sources(SECTIONS "${CMAKE_CURRENT_LIST_DIR}/toit-extension.ld")
  target_include_directories(app PRIVATE "${TOIT_ROOT}/src" "${TOIT_ROOT}/include"
    "${TOIT_ROOT}/third_party/esp-idf/components/mbedtls/mbedtls/include")
  target_compile_definitions(app PRIVATE MBEDTLS_CONFIG_FILE="${TOIT_ROOT}/mbedtls/include/zephyr_config.h")
  target_link_libraries(app PRIVATE toit_vm mbedtls mbedx509 mbedcrypto)

  set(network_image "")
  set(network_arguments "")
  if (CONFIG_SOC_NRF5340_CPUAPP AND CONFIG_BT_HCI_IPC)
    set(TOIT_ZEPHYR_NETWORK_IMAGE "" CACHE FILEPATH "Prebuilt matching nRF5340 controller; empty builds it automatically")
    if (TOIT_ZEPHYR_NETWORK_IMAGE)
      set(network_image "${TOIT_ZEPHYR_NETWORK_IMAGE}")
    else()
      # Keep the controller in a separate Zephyr build: its CPU, flash and RAM
      # configuration differ from the application, but its host interface must
      # use the same pinned source tree and connection count.
      set(network_board "${BOARD}")
      if (network_board MATCHES "/nrf5340/cpuapp$")
        string(REGEX REPLACE "/cpuapp$" "/cpunet" network_board "${network_board}")
      else()
        set(network_board "${BOARD}/nrf5340/cpunet")
      endif()
      set(TOIT_ZEPHYR_NETWORK_BOARD "${network_board}" CACHE STRING "Board target for the nRF5340 controller")
      set(network_image "${CMAKE_CURRENT_BINARY_DIR}/network/zephyr/zephyr.bin")
      set(network_cmake_arguments
        "-DZephyr_DIR=${Zephyr_DIR}"
        "-DBOARD=${TOIT_ZEPHYR_NETWORK_BOARD}"
        "-DBOARD_ROOT=${CMAKE_CURRENT_LIST_DIR}"
        "-DPython3_EXECUTABLE=${Python3_EXECUTABLE}"
        "-DZEPHYR_TOOLCHAIN_VARIANT=${ZEPHYR_TOOLCHAIN_VARIANT}"
        "-DEXTRA_CONF_FILE=${CMAKE_CURRENT_LIST_DIR}/hci-ipc.conf"
        "-DCONFIG_BT_MAX_CONN=${CONFIG_BT_MAX_CONN}")
      foreach(variable GNUARMEMB_TOOLCHAIN_PATH ZEPHYR_SDK_INSTALL_DIR)
        if (DEFINED ${variable})
          list(APPEND network_cmake_arguments "-D${variable}=${${variable}}")
        endif()
      endforeach()
      include(ExternalProject)
      ExternalProject_Add(toit_network_controller
        SOURCE_DIR "${ZEPHYR_BASE}/samples/bluetooth/hci_ipc"
        BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/network"
        CMAKE_ARGS ${network_cmake_arguments}
        BUILD_ALWAYS TRUE
        BUILD_BYPRODUCTS "${network_image}"
        INSTALL_COMMAND "")
    endif()
    list(APPEND network_arguments "--network.bin=${network_image}")
  endif()

  # The envelope carries every image bundled by this build. Extraction can
  # resize the final extension without relinking native code.
  set(envelope "${CMAKE_CURRENT_BINARY_DIR}/toit.envelope")
  set(envelope_commands "")
  set(image_index 0)
  foreach(image IN LISTS bundled_images)
    list(APPEND envelope_commands COMMAND "${TOIT_HOST}" run
      "${TOIT_ROOT}/tools/firmware.toit" -- --envelope=${envelope}
      container install "app${image_index}" "${image}")
    math(EXPR image_index "${image_index} + 1")
  endforeach()
  add_custom_command(OUTPUT "${envelope}"
    COMMAND "${TOIT_HOST}" run "${TOIT_ROOT}/tools/firmware.toit" --
      --envelope=${envelope} create-zephyr
      --firmware.bin=${CMAKE_CURRENT_BINARY_DIR}/zephyr/zephyr.bin
      --system.snapshot=${CMAKE_CURRENT_BINARY_DIR}/boot.snapshot
      ${network_arguments}
    ${envelope_commands}
    DEPENDS zephyr_final "boot.snapshot" ${bundled_images} "${TOIT_HOST}" ${network_image}
      "${TOIT_ROOT}/tools/firmware.toit" "${TOIT_ROOT}/tools/firmware/zephyr.toit"
    VERBATIM)
  add_custom_target(toit_envelope DEPENDS "${envelope}")
endif()

if (CONFIG_TOIT_PSA_CRYPTO AND NOT TOIT_ZEPHYR_BUILD_VM)
  message(FATAL_ERROR "Toit's PSA provider requires the VM's Mbed TLS and entropy support")
endif()

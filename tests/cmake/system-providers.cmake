# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the license in the LICENSE file.

include("${SOURCE_DIR}/toolchains/idf/components/toit/system-providers.cmake")

if(CHECK_INVALID_CONFIG)
    set(CONFIG_BT_CONTROLLER_ONLY OFF)
    set(CONFIG_TOIT_SYSTEM_BLE ON)
    toit_generate_system_entry("${OUTPUT_DIR}" "${SOURCE_DIR}/system")
    message(FATAL_ERROR "Accepted BLE provider without native transport")
endif()

# Reuse a directory to also check that reconfiguration removes stale imports.
set(ENTRY_DIR "${OUTPUT_DIR}/system with spaces")
foreach(CASE enabled disabled unsupported)
    set(CONFIG_BT_CONTROLLER_ONLY ON)
    set(CONFIG_TOIT_SYSTEM_BLE OFF)
    if(CASE STREQUAL "enabled")
        set(CONFIG_TOIT_SYSTEM_BLE ON)
    elseif(CASE STREQUAL "unsupported")
        set(CONFIG_BT_CONTROLLER_ONLY OFF)
    endif()
    toit_generate_system_entry("${ENTRY_DIR}" "${SOURCE_DIR}/system")
    execute_process(
        COMMAND "${TOIT}" compile --snapshot -O2
            --project-root "${SOURCE_DIR}/system"
            --dependency-file "${OUTPUT_DIR}/${CASE}.deps" --dependency-format plain
            -o "${OUTPUT_DIR}/${CASE}.snapshot" "${ENTRY_DIR}/boot.toit"
        RESULT_VARIABLE COMPILE_RESULT)
    if(NOT COMPILE_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to compile system with providers ${CASE}")
    endif()
    file(READ "${OUTPUT_DIR}/${CASE}.deps" DEPENDENCIES)
    if(CASE STREQUAL "enabled")
        if(NOT DEPENDENCIES MATCHES "/ble/implementation_/service/gatt-provider.toit")
            message(FATAL_ERROR "BLE provider missing from enabled system")
        endif()
    elseif(DEPENDENCIES MATCHES "/ble/" OR DEPENDENCIES MATCHES "/esp32/ble.toit")
        message(FATAL_ERROR "BLE code included in ${CASE} system")
    endif()
endforeach()

# Custom deployments can still compile the explicit no-BLE entry point.
execute_process(
    COMMAND "${TOIT}" compile --snapshot -O2
        --project-root "${SOURCE_DIR}/system"
        -o "${OUTPUT_DIR}/custom.snapshot"
        "${SOURCE_DIR}/system/extensions/esp32/boot-without-ble.toit"
    RESULT_VARIABLE COMPILE_RESULT)
if(NOT COMPILE_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to compile custom system entry point")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" "-DSOURCE_DIR=${SOURCE_DIR}" "-DOUTPUT_DIR=${OUTPUT_DIR}"
        -DCHECK_INVALID_CONFIG=ON -P "${CMAKE_CURRENT_LIST_FILE}"
    RESULT_VARIABLE INVALID_RESULT
    OUTPUT_VARIABLE INVALID_OUTPUT ERROR_VARIABLE INVALID_ERROR)
if(INVALID_RESULT EQUAL 0 OR NOT INVALID_ERROR MATCHES "requires CONFIG_BT_CONTROLLER_ONLY")
    message(FATAL_ERROR "Expected incompatible provider selection to fail: ${INVALID_OUTPUT}${INVALID_ERROR}")
endif()

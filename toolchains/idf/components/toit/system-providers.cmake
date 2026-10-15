# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the license in the LICENSE file.

# Generate the default system entry point with only the selected providers.
# Keep generated files in the build tree and reference the live system sources,
# so edits to those sources are picked up on the next firmware build.
function(toit_generate_system_entry OUTPUT_DIR SYSTEM_DIR)
    set(PROVIDERS "")
    if(CONFIG_TOIT_SYSTEM_BLE)
        if(NOT CONFIG_BT_CONTROLLER_ONLY)
            message(FATAL_ERROR "The system BLE provider requires CONFIG_BT_CONTROLLER_ONLY")
        endif()
        list(APPEND PROVIDERS ble)
    endif()

    set(TOIT_PROVIDER_IMPORTS "")
    set(TOIT_PROVIDER_INSTALLERS "")
    foreach(PROVIDER IN LISTS PROVIDERS)
        string(APPEND TOIT_PROVIDER_IMPORTS
            "import .system.extensions.esp32.${PROVIDER} show install-${PROVIDER}-service\n")
        string(APPEND TOIT_PROVIDER_INSTALLERS "    install-${PROVIDER}-service\n")
    endforeach()
    if(NOT PROVIDERS)
        set(TOIT_PROVIDER_INSTALLERS "    null\n")
    endif()

    file(MAKE_DIRECTORY "${OUTPUT_DIR}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E create_symlink "${SYSTEM_DIR}" "${OUTPUT_DIR}/system"
        RESULT_VARIABLE LINK_RESULT)
    if(NOT LINK_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not link system sources into ${OUTPUT_DIR}")
    endif()
    configure_file("${SYSTEM_DIR}/extensions/esp32/boot.toit.in"
                   "${OUTPUT_DIR}/boot.toit" @ONLY)
endfunction()

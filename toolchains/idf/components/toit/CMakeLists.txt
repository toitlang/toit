cmake_minimum_required(VERSION 3.11)

set(TOIT_BASE_DIR ${COMPONENT_PATH}/../../../..)

# Register without sources, this will create an INTERFACE lib and we can then specify link options later
idf_component_register(INCLUDE_DIRS "${TOIT_BASE_DIR}/src"
        REQUIRES "esp_adc_cal" "mbedtls" "bt" "app_update" "ulp")

cmake_policy(SET CMP0079 NEW)

set(TOIT_SYSTEM_NAME "esp32")

set(TOIT_INTERPRETER_FLAGS "-fno-crossjumping;-fno-tree-tail-merge" CACHE STRING "toit interpreter flags")

set(TOIT_SDK_DIR ${TOIT_BASE_DIR}/build/host/sdk)
set(TOIT_SDK_DIR ${TOIT_SDK_DIR} PARENT_SCOPE)
set(TOITC ${TOIT_SDK_DIR}/bin/toit.compile)
set(TOITPKG ${TOIT_SDK_DIR}/bin/toit.pkg)
set(TOIT_TOOLS_DIR ${TOIT_SDK_DIR}/tools)
set(FIRMWARE_BIN ${TOIT_TOOLS_DIR}/firmware)
set(CMAKE_BUILD_TYPE Release)

add_subdirectory(${TOIT_BASE_DIR} toit EXCLUDE_FROM_ALL)

# Add the include directories from the requires components to the imported toit_vm target
target_include_directories(toit_vm PRIVATE "$<TARGET_PROPERTY:${COMPONENT_LIB},INTERFACE_INCLUDE_DIRECTORIES>")

# idf cmake does not honor the CMAKE_BUILD_TARGET, so we can not use the CMAKE_C(XX)?_FLAGS.
# Add the required flags and defines with target_compile_* commands
target_compile_definitions(toit_vm PRIVATE
        -DDEPLOY=1
        -DTOIT_DEPLOY
        -DESP32
        -D__FREERTOS__
        -DRAW)

if (CONFIG_IDF_TARGET_ARCH_XTENSA)
    set(TOIT_ARCH_COMPILE_OPTIONS -mlongcalls)
else()
    set(TOIT_ARCH_COMPILE_OPTIONS -fpermissive -Wno-error=all)
endif()

target_compile_options(toit_vm PRIVATE
        -Wno-missing-field-initializers
        -Wno-ignored-qualifiers
        -Wno-sign-compare
        -Wno-extra
        -Wno-error=format
        -fjump-tables                   # idf (cmake) sets no-jump-tables which was not set by make
        -ftree-switch-conversion        # idf (cmake) sets no-jump-tables which was not set by make
        ${TOIT_ARCH_COMPILE_OPTIONS}
        )

target_link_libraries(${COMPONENT_LIB} INTERFACE toit_vm)
target_link_options(${COMPONENT_LIB} INTERFACE "SHELL: -Wl,--whole-archive $<TARGET_FILE:toit_vm> -Wl,--no-whole-archive")

idf_component_set_property(${COMPONENT_NAME} TOIT_SDK_DIR ${TOIT_SDK_DIR})
idf_component_set_property(${COMPONENT_NAME} SYSTEM_SNAPSHOT ${CMAKE_BINARY_DIR}/system.snapshot)
idf_component_set_property(${COMPONENT_NAME} TOITC ${TOITC})
idf_component_set_property(${COMPONENT_NAME} TOIT_BASE_DIR ${TOIT_BASE_DIR})
idf_build_set_property(TOIT_COMPONENT_NAME "${COMPONENT_NAME}")

function(toit_postprocess)
    idf_build_get_property(TOIT_COMPONENT_NAME TOIT_COMPONENT_NAME)
    idf_component_get_property(TOIT_SDK_DIR ${TOIT_COMPONENT_NAME} TOIT_SDK_DIR)
    idf_component_get_property(TOITC ${TOIT_COMPONENT_NAME} TOITC)
    idf_component_get_property(TOIT_BASE_DIR ${TOIT_COMPONENT_NAME} TOIT_BASE_DIR)
    idf_component_get_property(SYSTEM_SNAPSHOT ${TOIT_COMPONENT_NAME} SYSTEM_SNAPSHOT)
    set(FIRMWARE_BIN ${TOIT_SDK_DIR}/tools/firmware)

    idf_build_get_property(EXECUTABLE_NAME EXECUTABLE_NAME)

    add_custom_target(firmware ALL DEPENDS bootloader partition_table_bin gen_project_binary)
    add_dependencies(flash firmware)

    add_custom_command(
            TARGET firmware
            COMMAND ${TOITC} -w ${CMAKE_BINARY_DIR}/system.snapshot --project-root ${TOIT_BASE_DIR}/system ${TOIT_BASE_DIR}/system/extensions/esp32/boot.toit
            VERBATIM)

    add_custom_command(
            TARGET firmware
            COMMAND rm -f firmware.envelope
            COMMAND "${FIRMWARE_BIN}"
            "--envelope=firmware.envelope"
            "create"
            "--bootloader.bin=bootloader/bootloader.bin"
            "--firmware.bin=${EXECUTABLE_NAME}.bin"
            "--firmware.elf=${EXECUTABLE_NAME}.elf"
            "--partitions.bin=partition_table/partition-table.bin"
            "--partitions.csv=${CMAKE_HOME_DIRECTORY}/partitions.csv"
            "--system.snapshot=${SYSTEM_SNAPSHOT}"
            COMMAND echo envelope: created
    )

    if (CONFIG_TOIT_WIFI_SSID AND CONFIG_TOIT_WIFI_PASSWORD)
        add_custom_command(
                TARGET firmware
                COMMAND "${FIRMWARE_BIN}"
                "--envelope=firmware.envelope"
                "property" "set" "wifi" "'{\"wifi.ssid\":\"${CONFIG_TOIT_WIFI_SSID}\",\"wifi.password\":\"${CONFIG_TOIT_WIFI_PASSWORD}\"}'"
                COMMAND echo envelope: set wifi
        )
    endif()

    if (CONFIG_TOIT_ENTRY_POINT)
        set(RUN_PROGRAM true)
        if (NOT EXISTS "${CONFIG_TOIT_ENTRY_POINT}")
            message(WARNING "Could not find entry point: ${CONFIG_TOIT_ENTRY_POINT}")
            set(RUN_PROGRAM false)
        endif()

        if (CONFIG_TOIT_ENTRY_POINT_PROJECT_ROOT)
            if (NOT EXISTS "${CONFIG_TOIT_ENTRY_POINT_PROJECT_ROOT}")
                message(WARNING "Could not find project root of entry point: ${CONFIG_TOIT_ENTRY_POINT_PROJECT_ROOT}")
                set(RUN_PROGRAM false)
            endif()
            set(ENTRY_PROJECT_ROOT_ARGS "--project-root" "${CONFIG_TOIT_ENTRY_POINT_PROJECT_ROOT}")
        endif()

        if (RUN_PROGRAM)
            add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/program.snapshot
                    COMMAND "${TOITC}" "-w" "${CMAKE_BINARY_DIR}/program.snapshot" ${ENTRY_PROJECT_ROOT_ARGS} ${CONFIG_TOIT_ENTRY_POINT}
                    VERBATIM)

            add_custom_target(program_snapshot DEPENDS ${CMAKE_BINARY_DIR}/program.snapshot)
            add_dependencies(firmware program_snapshot)

            add_custom_command(
                    TARGET firmware
                    COMMAND "${FIRMWARE_BIN}"
                    "--envelope=firmware.envelope"
                    "container" "install" "program" ${CMAKE_BINARY_DIR}/program.snapshot
                    COMMAND echo envelope: program added
            )
        endif()
    endif()

    add_custom_command(
            TARGET firmware
            COMMAND "${FIRMWARE_BIN}"
            "--envelope=firmware.envelope"
            "extract" "--firmware.bin" "-o" "${EXECUTABLE_NAME}-firmware.bin"
            COMMAND echo envelope: firmware extracted
    )

    add_custom_target(mod_flash_args DEPENDS firmware)
    add_dependencies(flash mod_flash_args)
    add_custom_command(
            TARGET mod_flash_args
            COMMAND sed -i s/${EXECUTABLE_NAME}\\.bin/${EXECUTABLE_NAME}-firmware\\.bin/g ${CMAKE_BINARY_DIR}/flash_args
            COMMAND echo MID: MOD FLASH ARGS
            COMMAND cat ${CMAKE_BINARY_DIR}/flash_args
    )

endfunction()

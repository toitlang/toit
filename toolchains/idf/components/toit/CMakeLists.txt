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

# Add the include directories from the required components to the imported toit_vm target.
target_include_directories(toit_vm PRIVATE "$<TARGET_PROPERTY:${COMPONENT_LIB},INTERFACE_INCLUDE_DIRECTORIES>")

# idf cmake does not honor the CMAKE_BUILD_TARGET, so we can not use the CMAKE_C(XX)?_FLAGS.
# Add the required flags and defines with target_compile_* commands.
target_compile_definitions(toit_vm PUBLIC
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

# The idf cmake system adds some compile flags that if not undone causes the toit compile to fail.
# -Wextra combined with -Werror=all causes the Toit code to not compile.
target_compile_options(toit_vm PRIVATE
        -fjump-tables                   # idf (cmake) sets no-jump-tables which was not set by make.
        -ftree-switch-conversion        # idf (cmake) sets no-tree-switch-conversion which was not set by make.
        ${TOIT_ARCH_COMPILE_OPTIONS}
        )

target_link_libraries(${COMPONENT_LIB} INTERFACE toit_vm)
target_link_options(${COMPONENT_LIB} INTERFACE "SHELL: -Wl,--whole-archive $<TARGET_FILE:toit_vm> -Wl,--no-whole-archive")

idf_component_set_property(${COMPONENT_NAME} TOIT_SDK_DIR ${TOIT_SDK_DIR})
idf_component_set_property(${COMPONENT_NAME} SYSTEM_SNAPSHOT ${CMAKE_BINARY_DIR}/system.snapshot)
idf_component_set_property(${COMPONENT_NAME} TOITC ${TOITC})
idf_component_set_property(${COMPONENT_NAME} TOIT_BASE_DIR ${TOIT_BASE_DIR})
idf_build_set_property(TOIT_COMPONENT_NAME "${COMPONENT_NAME}")

# Try to resolve a file or path given in the sdkconfig.
# The order of resolution is:
#   1. Absolute path (or relative to this CMakeFile (unlikely))
#   2. Path relative to main projects directory
#   3. Path relative to the base dir of toit
function(resolve_file out in toit_base_dir warning_text)
    set(result ${in})
    if (NOT EXISTS ${result})
        set(result ${CMAKE_HOME_DIRECTORY}/${in})
        if (NOT EXISTS ${result})
            set(result ${toit_base_dir}/${in})
            if (NOT EXISTS ${result})
                if(warning_text)
                    message(WARNING "Missing ${warning_text} file ${in}. Build will fail")
                endif()
            endif()
        endif()
    endif()
    set(${out} ${result} PARENT_SCOPE)
endfunction()

function(toit_postprocess)
    idf_build_get_property(TOIT_COMPONENT_NAME TOIT_COMPONENT_NAME)
    idf_component_get_property(TOIT_SDK_DIR ${TOIT_COMPONENT_NAME} TOIT_SDK_DIR)
    idf_component_get_property(TOITC ${TOIT_COMPONENT_NAME} TOITC)
    idf_component_get_property(TOIT_BASE_DIR ${TOIT_COMPONENT_NAME} TOIT_BASE_DIR)
    idf_component_get_property(SYSTEM_SNAPSHOT ${TOIT_COMPONENT_NAME} SYSTEM_SNAPSHOT)
    set(FIRMWARE_BIN ${TOIT_SDK_DIR}/tools/firmware)
    set(ASSETS_BIN ${TOIT_SDK_DIR}/tools/assets)

    idf_build_get_property(EXECUTABLE_NAME EXECUTABLE_NAME)

    add_custom_target(firmware ALL DEPENDS bootloader partition_table_bin gen_project_binary)
    add_dependencies(flash firmware)
    resolve_file(BOOT ${CONFIG_TOIT_SYSTEM_SOURCE} ${TOIT_BASE_DIR} "system toit")
    resolve_file(BOOT_PROJECT_ROOT ${CONFIG_TOIT_SYSTEM_SOURCE_PROJECT_ROOT} ${TOIT_BASE_DIR} "")

    if (EXISTS ${BOOT_PROJECT_ROOT})
        set(BOOT_PROJECT_ROOT_ARGS "--project-root" "${BOOT_PROJECT_ROOT}")
    else()
        message(WARNING "Missing project root for system toit file: ${CONFIG_TOIT_SYSTEM_SOURCE_PROJECT_ROOT}. Build might fail")
    endif()


    add_custom_command(
            TARGET firmware
            POST_BUILD
            COMMAND ${TOITC} -w ${CMAKE_BINARY_DIR}/system.snapshot ${BOOT_PROJECT_ROOT_ARGS} ${BOOT}
            VERBATIM)

    add_custom_command(
            TARGET firmware
            POST_BUILD
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
                POST_BUILD
                COMMAND "${FIRMWARE_BIN}"
                        "--envelope=firmware.envelope"
                        "property" "set" "wifi" "'{\"wifi.ssid\":\"${CONFIG_TOIT_WIFI_SSID}\",\"wifi.password\":\"${CONFIG_TOIT_WIFI_PASSWORD}\"}'"
                COMMAND echo envelope: set wifi
        )
    endif()



    if (CONFIG_TOIT_ENTRY_POINT)
        resolve_file(RUN_PROGRAM ${CONFIG_TOIT_ENTRY_POINT} ${TOIT_BASE_DIR} "program toit")
        resolve_file(RUN_PROGRAM_PROJECT_ROOT "${CONFIG_TOIT_ENTRY_POINT_PROJECT_ROOT}" ${TOIT_BASE_DIR} "")
        resolve_file(RUN_PROGRAM_ASSETS_FILE "${CONFIG_TOIT_ENTRY_POINT_ASSETS_FILE}" ${TOIT_BASE_DIR} "")

        if(CONFIG_TOIT_ENTRY_POINT_PROJECT_ROOT AND EXISTS ${RUN_PROGRAM_PROJECT_ROOT})
            set(ENTRY_PROJECT_ROOT_ARGS "--project-root" "${RUN_PROGRAM_PROJECT_ROOT}")
        endif()

        IF(CONFIG_TOIT_ENTRY_POINT_ASSETS_FILE AND EXISTS ${RUN_PROGRAM_ASSETS_FILE})
            get_filename_component(ASSET_NAME ${RUN_PROGRAM_ASSETS_FILE} NAME_WLE)
            message("${ASSET_NAME}")
            add_custom_command(
                    TARGET firmware
                    POST_BUILD
                    COMMAND "${ASSETS_BIN}" "--assets=entry_assets.bin" create
                    COMMAND "${ASSETS_BIN}" "--assets=entry_assets.bin" "add" "--format" "ubjson"
                            ${ASSET_NAME} ${RUN_PROGRAM_ASSETS_FILE}
                    COMMAND echo envelope: asset for program created
            )
            set(ENTRY_ASSETS_ARGS "--assets" "entry_assets.bin")
        endif()

        add_custom_command(
                TARGET firmware
                POST_BUILD
                COMMAND "${TOITC}" "-w" "${CMAKE_BINARY_DIR}/program.snapshot" ${ENTRY_PROJECT_ROOT_ARGS} ${RUN_PROGRAM}
                COMMAND "${FIRMWARE_BIN}" "--envelope=firmware.envelope"
                        "container" "install" ${ENTRY_ASSETS_ARGS} "program" ${CMAKE_BINARY_DIR}/program.snapshot
                COMMAND echo envelope: program added
        )


    endif()

    add_custom_command(
            TARGET firmware
            POST_BUILD
            COMMAND "${FIRMWARE_BIN}"
                    "--envelope=firmware.envelope"
                    "extract" "--firmware.bin" "-o" "${EXECUTABLE_NAME}-firmware.bin"
            COMMAND echo envelope: firmware extracted
    )

    add_custom_target(mod_flash_args DEPENDS firmware)
    add_dependencies(flash mod_flash_args)
    add_dependencies(app mod_flash_args)
    # To convince idf.py that it should flash the generated binary from the firmware tool, the flash_args file
    # is updated with an alternative name for the application binary
    add_custom_command(
            TARGET mod_flash_args
            POST_BUILD
            COMMAND sed -i s/${EXECUTABLE_NAME}\\.bin/${EXECUTABLE_NAME}-firmware\\.bin/g ${CMAKE_BINARY_DIR}/flash_args
            COMMAND sed -i s/${EXECUTABLE_NAME}\\.bin/${EXECUTABLE_NAME}-firmware\\.bin/g ${CMAKE_BINARY_DIR}/flasher_args.json
    )

endfunction()

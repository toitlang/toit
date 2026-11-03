cmake_minimum_required(VERSION 3.11)

set(TOIT_BASE_DIR ${COMPONENT_PATH}/../../../..)

# esp_psram is listed explicitly so that a build restricted with -DCOMPONENTS
# still initializes PSRAM; nothing else pulls it in once lwIP is not built.
set(TOIT_COMPONENT_REQUIRES
        "efuse" "esp_adc" "esp_eth" "esp_hw_support" "esp_netif" "esp_psram" "esp_rom"
        "nvs_flash" "spi_flash" "mbedtls" "bt" "app_update" "ulp" "fatfs")
if(CONFIG_TOIT_ENABLE_SPI_TARGET AND CONFIG_SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE)
    list(APPEND TOIT_COMPONENT_REQUIRES "esp_mm")
endif()

# Register without sources, this will create an INTERFACE lib and we can then specify link options later
idf_component_register(INCLUDE_DIRS "${TOIT_BASE_DIR}/src" "${TOIT_BASE_DIR}/include"
        REQUIRES ${TOIT_COMPONENT_REQUIRES})

cmake_policy(SET CMP0079 NEW)

set(TOIT_SYSTEM_NAME "esp32")

set(TOIT_INTERPRETER_FLAGS "-fno-crossjumping;-fno-tree-tail-merge" CACHE STRING "toit interpreter flags")

# If TOIT_SDK_DIR is not set, do it now.
if (NOT TOIT_SDK_DIR)
    set(TOIT_SDK_DIR ${TOIT_BASE_DIR}/build/host/sdk)
endif()
set(TOIT_SDK_DIR ${TOIT_SDK_DIR} PARENT_SCOPE)
set(TOIT ${TOIT_SDK_DIR}/bin/toit)
set(CMAKE_BUILD_TYPE Release)

# A native support build has the native runtime, but no generated code. It packs
# what it takes to link firmware with generated code later, so the firmware
# tool can extract native firmware from an envelope with the native support.
set(TOIT_NATIVE_SUPPORT "$ENV{TOIT_NATIVE_SUPPORT}")
set(TOIT_NATIVE_EMBEDDED FALSE)
if (TOIT_NATIVE_SUPPORT)
    set(TOIT_NATIVE_EMBEDDED TRUE)
endif()
# The flags that generated code is compiled with. The ESP32-C3 has no atomic
# instructions, so Clang calls the library for atomic loads, which takes a
# lock. With forced atomics it loads and stores words directly, like GCC does
# for the rest of the firmware. Clang still warns that the loads aren't lock
# free, because the warning doesn't know about forced atomics.
set(TOIT_NATIVE_CXX_FLAGS
    --target=riscv32-esp-elf -march=rv32imc_zicsr_zifencei -mabi=ilp32
    -Xclang -target-feature -Xclang +forced-atomics -Wno-atomic-alignment
    -Wno-missing-multilib
    -std=gnu++11 -ffreestanding -fno-exceptions -fno-rtti -ffunction-sections -fdata-sections
    -O2)

add_subdirectory(${TOIT_BASE_DIR} toit EXCLUDE_FROM_ALL)

# Add the include directories from the required components to the imported toit_vm target.
target_include_directories(toit_vm PRIVATE "$<TARGET_PROPERTY:${COMPONENT_LIB},INTERFACE_INCLUDE_DIRECTORIES>")
if(CONFIG_TOIT_ENABLE_SPI_TARGET AND CONFIG_SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE)
    target_include_directories(toit_vm PRIVATE "$<TARGET_PROPERTY:idf::esp_mm,INTERFACE_INCLUDE_DIRECTORIES>")
endif()

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

if (TOIT_NATIVE_EMBEDDED AND NOT CONFIG_IDF_TARGET_ESP32C3)
    message(FATAL_ERROR "Firmware with native code is only supported for the ESP32-C3")
endif()

idf_component_set_property(${COMPONENT_NAME} TOIT_NATIVE_SUPPORT "${TOIT_NATIVE_SUPPORT}")
idf_component_set_property(${COMPONENT_NAME} TOIT_NATIVE_CXX_FLAGS "${TOIT_NATIVE_CXX_FLAGS}")

idf_component_set_property(${COMPONENT_NAME} TOIT_SDK_DIR ${TOIT_SDK_DIR})
idf_component_set_property(${COMPONENT_NAME} SYSTEM_SNAPSHOT ${CMAKE_BINARY_DIR}/system.snapshot)
idf_component_set_property(${COMPONENT_NAME} TOIT ${TOIT})
idf_component_set_property(${COMPONENT_NAME} TOIT_BASE_DIR ${TOIT_BASE_DIR})
idf_build_set_property(TOIT_COMPONENT_NAME "${COMPONENT_NAME}")

include(${CMAKE_CURRENT_LIST_DIR}/resolve_file.cmake)

function(toit_postprocess)
    idf_build_get_property(TOIT_COMPONENT_NAME TOIT_COMPONENT_NAME)
    idf_component_get_property(TOIT_SDK_DIR ${TOIT_COMPONENT_NAME} TOIT_SDK_DIR)
    idf_component_get_property(TOIT ${TOIT_COMPONENT_NAME} TOIT)
    idf_component_get_property(TOIT_BASE_DIR ${TOIT_COMPONENT_NAME} TOIT_BASE_DIR)
    idf_component_get_property(SYSTEM_SNAPSHOT ${TOIT_COMPONENT_NAME} SYSTEM_SNAPSHOT)
    idf_component_get_property(NATIVE_SUPPORT ${TOIT_COMPONENT_NAME} TOIT_NATIVE_SUPPORT)

    idf_build_get_property(EXECUTABLE_NAME EXECUTABLE_NAME)

    add_custom_target(firmware ALL DEPENDS bootloader partition_table_bin gen_project_binary)
    # The envelope packaging below reads ota_data_initial.bin.
    if(TARGET blank_ota_data)
        add_dependencies(firmware blank_ota_data)
    endif()
    add_dependencies(flash firmware)
    resolve_file(BOOT ${CONFIG_TOIT_SYSTEM_SOURCE} ${TOIT_BASE_DIR} "system toit")
    resolve_file(BOOT_PROJECT_ROOT ${CONFIG_TOIT_SYSTEM_SOURCE_PROJECT_ROOT} ${TOIT_BASE_DIR} "")

    if (EXISTS ${BOOT_PROJECT_ROOT})
        set(BOOT_PROJECT_ROOT_ARGS "--project-root" "${BOOT_PROJECT_ROOT}")
    else()
        message(WARNING "Missing project root for system toit file: ${CONFIG_TOIT_SYSTEM_SOURCE_PROJECT_ROOT}. Build might fail")
    endif()

    if (NATIVE_SUPPORT)
        # A native support build only packs the native support. Its firmware has no program.
        idf_build_get_property(PYTHON PYTHON)
        idf_build_get_property(IDF_PATH IDF_PATH)
        idf_build_get_property(IDF_TARGET IDF_TARGET)
        idf_component_get_property(NATIVE_CXX_FLAGS ${TOIT_COMPONENT_NAME} TOIT_NATIVE_CXX_FLAGS)
        string(REPLACE ";" " " NATIVE_CXX_FLAGS "${NATIVE_CXX_FLAGS}")
        # The toolchain's strip is next to its objcopy.
        get_filename_component(OBJCOPY_DIR "${CMAKE_OBJCOPY}" DIRECTORY)
        get_filename_component(OBJCOPY_NAME "${CMAKE_OBJCOPY}" NAME)
        string(REPLACE "objcopy" "strip" STRIP_NAME "${OBJCOPY_NAME}")
        set(STRIP "${OBJCOPY_DIR}/${STRIP_NAME}")
        add_custom_command(
                TARGET firmware
                POST_BUILD
                COMMAND "${PYTHON}" "${TOIT_BASE_DIR}/toolchains/idf/components/toit/native_support.py"
                        "--build-dir=${CMAKE_BINARY_DIR}"
                        "--idf-path=${IDF_PATH}"
                        "--ninja=${CMAKE_MAKE_PROGRAM}"
                        "--strip=${STRIP}"
                        "--elf=${EXECUTABLE_NAME}.elf"
                        "--binary-target=.bin_timestamp"
                        "--chip=${IDF_TARGET}"
                        "--cxx-flags=${NATIVE_CXX_FLAGS}"
                        "--toit=${TOIT}"
                        "-o" "${CMAKE_BINARY_DIR}/native-support.tar.gz"
                COMMAND echo native support: created
                VERBATIM)
        return()
    endif()

    add_custom_command(
            TARGET firmware
            POST_BUILD
            COMMAND ${TOIT} compile --snapshot -O2 -o ${CMAKE_BINARY_DIR}/system.snapshot ${BOOT_PROJECT_ROOT_ARGS} ${BOOT}
            VERBATIM)

    add_custom_command(
            TARGET firmware
            POST_BUILD
            COMMAND rm -f firmware.envelope
            COMMAND "${TOIT}" tool firmware
                    "--envelope=firmware.envelope"
                    "create" "esp32"
                    "--bootloader.bin=bootloader/bootloader.bin"
                    "--firmware.bin=${EXECUTABLE_NAME}.bin"
                    "--firmware.elf=${EXECUTABLE_NAME}.elf"
                    "--partitions.bin=partition_table/partition-table.bin"
                    "--otadata.bin=ota_data_initial.bin"
                    "--flashing.json=flasher_args.json"
                    "--system.snapshot=${SYSTEM_SNAPSHOT}"
            COMMAND echo envelope: created
    )

    if (CONFIG_TOIT_WIFI_SSID AND CONFIG_TOIT_WIFI_PASSWORD)
        add_custom_command(
                TARGET firmware
                POST_BUILD
                COMMAND "${TOIT}" tool firmware
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
                    COMMAND "${TOIT}" tool assets "--assets=entry_assets.bin" create
                    COMMAND "${TOIT}" tool assets "--assets=entry_assets.bin" "add" "--format" "ubjson"
                            ${ASSET_NAME} ${RUN_PROGRAM_ASSETS_FILE}
                    COMMAND echo envelope: asset for program created
            )
            set(ENTRY_ASSETS_ARGS "--assets" "entry_assets.bin")
        endif()

        add_custom_command(
                TARGET firmware
                POST_BUILD
                COMMAND "${TOIT}" compile --snapshot -o "${CMAKE_BINARY_DIR}/program.snapshot" ${ENTRY_PROJECT_ROOT_ARGS} ${RUN_PROGRAM}
                COMMAND "${TOIT}" tool firmware "--envelope=firmware.envelope"
                        "container" "install" ${ENTRY_ASSETS_ARGS} "program" ${CMAKE_BINARY_DIR}/program.snapshot
                COMMAND echo envelope: program added
        )
    endif()

    add_custom_command(
            TARGET firmware
            POST_BUILD
            COMMAND "${TOIT}" tool firmware
                    "--envelope=firmware.envelope"
                    "extract" "--format=binary" "-o" "${EXECUTABLE_NAME}-firmware.bin"
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
            COMMAND sed -i.orig s/${EXECUTABLE_NAME}\\.bin/${EXECUTABLE_NAME}-firmware\\.bin/g ${CMAKE_BINARY_DIR}/flash_args
            COMMAND sed -i.orig s/${EXECUTABLE_NAME}\\.bin/${EXECUTABLE_NAME}-firmware\\.bin/g ${CMAKE_BINARY_DIR}/flasher_args.json
    )

endfunction()

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

# The verified core (verified/CMakeLists.txt): off unless selected in
# menuconfig; only RISC-V parts with atomics (see Kconfig).
if (CONFIG_TOIT_VERIFIED_CORE)
    set(TOIT_VERIFIED_CORE ON CACHE BOOL "" FORCE)
    if (CONFIG_IDF_TARGET_ESP32)
      # Experiment (verified/XTENSA-RUST-FIXES.md): the esp-rs fork.
      set(TOIT_VERIFIED_CORE_RUST_TARGET "xtensa-esp32-none-elf" CACHE STRING "" FORCE)
      set(TOIT_VERIFIED_CORE_CARGO_TOOLCHAIN "+esp" CACHE STRING "" FORCE)
      set(TOIT_VERIFIED_CORE_CARGO_ARGS "-Zbuild-std=core,alloc" CACHE STRING "" FORCE)
    elseif (CONFIG_IDF_TARGET_ESP32S3)
      # Xtensa LX7 with the same esp-rs fork (docs/format2-migration.md,
      # "Devices: hardware results").
      set(TOIT_VERIFIED_CORE_RUST_TARGET "xtensa-esp32s3-none-elf" CACHE STRING "" FORCE)
      set(TOIT_VERIFIED_CORE_CARGO_TOOLCHAIN "+esp" CACHE STRING "" FORCE)
      set(TOIT_VERIFIED_CORE_CARGO_ARGS "-Zbuild-std=core,alloc" CACHE STRING "" FORCE)
    else()
      set(TOIT_VERIFIED_CORE_RUST_TARGET "riscv32imac-unknown-none-elf" CACHE STRING "" FORCE)
    endif()
    set(TOIT_VERIFIED_CORE_OPT_LEVEL "${CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL}" CACHE STRING "" FORCE)
    if (CONFIG_TOIT_VERIFIED_CORE_VERIFIER)
        set(TOIT_VERIFIED_CORE_VERIFIER ON CACHE BOOL "" FORCE)
    else()
        set(TOIT_VERIFIED_CORE_VERIFIER OFF CACHE BOOL "" FORCE)
    endif()
    if (CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM)
        set(TOIT_VERIFIED_CORE_LOOP_IN_IRAM ON CACHE BOOL "" FORCE)
    else()
        set(TOIT_VERIFIED_CORE_LOOP_IN_IRAM OFF CACHE BOOL "" FORCE)
    endif()
    if (CONFIG_TOIT_VERIFIED_CORE_SPLIT_LOOP)
        set(TOIT_VERIFIED_CORE_SPLIT_LOOP ON CACHE BOOL "" FORCE)
    else()
        set(TOIT_VERIFIED_CORE_SPLIT_LOOP OFF CACHE BOOL "" FORCE)
    endif()
    set(TOIT_VERIFIED_CORE_IRAM_FUNCTIONS "${CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS}" CACHE STRING "" FORCE)
    set(TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL "${CONFIG_TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL}" CACHE STRING "" FORCE)
    if (CONFIG_TOIT_VERIFIED_CORE_INFER)
        set(TOIT_VERIFIED_CORE_INFER ON CACHE BOOL "" FORCE)
    else()
        set(TOIT_VERIFIED_CORE_INFER OFF CACHE BOOL "" FORCE)
    endif()
    if (CONFIG_TOIT_VERIFIED_CORE_CHECKED_LOOP)
        set(TOIT_VERIFIED_CORE_CHECKED_LOOP ON CACHE BOOL "" FORCE)
    else()
        set(TOIT_VERIFIED_CORE_CHECKED_LOOP OFF CACHE BOOL "" FORCE)
    endif()
else()
    set(TOIT_VERIFIED_CORE OFF CACHE BOOL "" FORCE)
endif()

# The bytecode format of the firmware's own programs (the system snapshot
# and the entry program) and whether the C++ interpreter for format 1 is
# linked (Kconfig TOIT_BYTECODE_FORMAT_2, TOIT_CXX_INTERPRETER;
# docs/format2-migration.md, "Devices"). The envelope records the formats
# the firmware runs.
if (CONFIG_TOIT_BYTECODE_FORMAT_2)
    set(TOIT_BYTECODE_FORMAT 2 CACHE STRING "" FORCE)
else()
    set(TOIT_BYTECODE_FORMAT 1 CACHE STRING "" FORCE)
endif()
if (CONFIG_TOIT_CXX_INTERPRETER)
    set(TOIT_CXX_INTERPRETER ON CACHE BOOL "" FORCE)
else()
    set(TOIT_CXX_INTERPRETER OFF CACHE BOOL "" FORCE)
endif()
set(TOIT_DEVICE_BYTECODE_FORMATS "")
if (CONFIG_TOIT_CXX_INTERPRETER)
    list(APPEND TOIT_DEVICE_BYTECODE_FORMATS 1)
endif()
if (CONFIG_TOIT_VERIFIED_CORE)
    list(APPEND TOIT_DEVICE_BYTECODE_FORMATS 2)
endif()
list(JOIN TOIT_DEVICE_BYTECODE_FORMATS "," TOIT_DEVICE_BYTECODE_FORMATS)

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

# The hot flash code (Kconfig TOIT_PIN_HOT_FLASH_CODE): an output section
# inserted before ESP-IDF's .flash.text, so at the start of the
# flash-mapped instructions (0x400d0020 on the classic ESP32), that holds
# the functions of the hot list in its order, each function's literals
# right before its code (L32R reaches only backwards). Their addresses, and
# so their flash-cache sets, then no longer depend on the size of any other
# code. An entry is a glob for the section names after ".text."/
# ".literal."; gcc's clones ($part$N, $constprop$N, $isra$N on Xtensa) come
# with their function. Functions that are in IRAM (IRAM_ATTR, ldgen
# fragments, TOIT_VERIFIED_CORE_IRAM_FUNCTIONS) have other section names
# or are claimed by .iram0.text first and stay there; entries that match
# nothing are ignored. toit_postprocess() puts the script before ESP-IDF's
# sections.ld on the link line (ld resolves INSERT only against scripts
# read after it).
if (CONFIG_TOIT_PIN_HOT_FLASH_CODE)
    if (NOT "${CONFIG_TOIT_HOT_FLASH_FUNCTIONS}" STREQUAL "")
        string(REPLACE "," ";" toit_hot_functions "${CONFIG_TOIT_HOT_FLASH_FUNCTIONS}")
    else()
        # The default list (hot_flash_functions.txt): one glob per line,
        # '#' starts a comment; "f1:"/"f2:" restricts a line to firmware
        # whose programs are format 1 / format 2 (the hot C++ helpers
        # differ: format 2 has the verified core's, format 1 the C++
        # interpreter's).
        set(toit_hot_file "${CMAKE_CURRENT_LIST_DIR}/hot_flash_functions.txt")
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${toit_hot_file}")
        file(STRINGS "${toit_hot_file}" toit_hot_lines)
        set(toit_hot_functions "")
        foreach (line IN LISTS toit_hot_lines)
            string(REGEX REPLACE "#.*" "" line "${line}")
            string(STRIP "${line}" line)
            if (line MATCHES "^f([12]):(.*)$")
                if (NOT CMAKE_MATCH_1 STREQUAL "${TOIT_BYTECODE_FORMAT}")
                    continue()
                endif()
                set(line "${CMAKE_MATCH_2}")
                string(STRIP "${line}" line)
            endif()
            if (NOT line STREQUAL "")
                list(APPEND toit_hot_functions "${line}")
            endif()
        endforeach()
    endif()
    set(toit_hot_body "")
    foreach (f IN LISTS toit_hot_functions)
        string(STRIP "${f}" f)
        if (f MATCHES "^@align +(0x[0-9a-fA-F]+|[0-9]+)$")
            # "@align N": the next entries start at an address that is a
            # multiple of N (a group whose cache sets must not depend on
            # the size of the entries before it).
            string(APPEND toit_hot_body "    . = ALIGN(${CMAKE_MATCH_1});\n")
        elseif (NOT f STREQUAL "")
            # A C++ constructor or destructor (C1/C2, D0/D1/D2) emitted in a
            # comdat group has its literals in the group's section (C5/D5).
            # A literal left behind in .flash.text fails the link ("l32r:
            # literal placed after use"): remove such an entry.
            set(lit "")
            if (f MATCHES "[CD][0-2]E")
                string(REGEX REPLACE "([CD])[0-2]E" "\\15E" f5 "${f}")
                set(lit " .literal.${f5}")
            endif()
            string(APPEND toit_hot_body "    *(.literal.${f} .literal.${f}.* .literal.${f}$*${lit})\n    *(.text.${f} .text.${f}.* .text.${f}$*)\n")
        endif()
    endforeach()
    set(TOIT_HOT_FLASH_LD "${CMAKE_CURRENT_BINARY_DIR}/toit_hot_flash.ld")
    file(CONFIGURE OUTPUT "${TOIT_HOT_FLASH_LD}" CONTENT
"/* Generated by the toit component (Kconfig TOIT_PIN_HOT_FLASH_CODE,
   TOIT_HOT_FLASH_FUNCTIONS). */
SECTIONS
{
  .flash.toit_hot :
  {
    _toit_hot_flash_start = ABSOLUTE(.);
${toit_hot_body}    _toit_hot_flash_end = ABSOLUTE(.);
  } > default_code_seg
}
INSERT BEFORE .flash.text;
" @ONLY)
    idf_component_set_property(${COMPONENT_NAME} TOIT_HOT_FLASH_LD "${TOIT_HOT_FLASH_LD}")
endif()

target_link_libraries(${COMPONENT_LIB} INTERFACE toit_vm)
target_link_options(${COMPONENT_LIB} INTERFACE "SHELL: -Wl,--whole-archive $<TARGET_FILE:toit_vm> -Wl,--no-whole-archive")

idf_component_set_property(${COMPONENT_NAME} TOIT_SDK_DIR ${TOIT_SDK_DIR})
idf_component_set_property(${COMPONENT_NAME} SYSTEM_SNAPSHOT ${CMAKE_BINARY_DIR}/system.snapshot)
idf_component_set_property(${COMPONENT_NAME} TOIT ${TOIT})
idf_component_set_property(${COMPONENT_NAME} TOIT_BASE_DIR ${TOIT_BASE_DIR})
idf_component_set_property(${COMPONENT_NAME} TOIT_BYTECODE_FORMAT ${TOIT_BYTECODE_FORMAT})
idf_component_set_property(${COMPONENT_NAME} TOIT_DEVICE_BYTECODE_FORMATS ${TOIT_DEVICE_BYTECODE_FORMATS})
idf_build_set_property(TOIT_COMPONENT_NAME "${COMPONENT_NAME}")

include(${CMAKE_CURRENT_LIST_DIR}/resolve_file.cmake)

function(toit_postprocess)
    idf_build_get_property(TOIT_COMPONENT_NAME TOIT_COMPONENT_NAME)
    idf_component_get_property(TOIT_SDK_DIR ${TOIT_COMPONENT_NAME} TOIT_SDK_DIR)
    idf_component_get_property(TOIT ${TOIT_COMPONENT_NAME} TOIT)
    idf_component_get_property(TOIT_BASE_DIR ${TOIT_COMPONENT_NAME} TOIT_BASE_DIR)
    idf_component_get_property(SYSTEM_SNAPSHOT ${TOIT_COMPONENT_NAME} SYSTEM_SNAPSHOT)

    idf_component_get_property(TOIT_BYTECODE_FORMAT ${TOIT_COMPONENT_NAME} TOIT_BYTECODE_FORMAT)
    idf_component_get_property(TOIT_DEVICE_BYTECODE_FORMATS ${TOIT_COMPONENT_NAME} TOIT_DEVICE_BYTECODE_FORMATS)

    idf_build_get_property(EXECUTABLE_NAME EXECUTABLE_NAME)

    # The hot flash code's linker script (TOIT_PIN_HOT_FLASH_CODE) goes
    # right before ESP-IDF's sections.ld (after memory.ld, whose regions it
    # uses): ld resolves its INSERT BEFORE .flash.text only against scripts
    # read after it. The scripts are esp_system's interface link options.
    idf_component_get_property(TOIT_HOT_FLASH_LD ${TOIT_COMPONENT_NAME} TOIT_HOT_FLASH_LD)
    if (TOIT_HOT_FLASH_LD)
        idf_component_get_property(system_lib esp_system COMPONENT_LIB)
        get_target_property(system_link_options ${system_lib} INTERFACE_LINK_OPTIONS)
        list(FIND system_link_options "SHELL:-T sections.ld" sections_index)
        if (sections_index LESS 0)
            message(FATAL_ERROR "TOIT_PIN_HOT_FLASH_CODE: no sections.ld in esp_system's link options")
        endif()
        get_filename_component(hot_dir "${TOIT_HOT_FLASH_LD}" DIRECTORY)
        get_filename_component(hot_name "${TOIT_HOT_FLASH_LD}" NAME)
        list(INSERT system_link_options ${sections_index} "SHELL:-T ${hot_name}")
        set_target_properties(${system_lib} PROPERTIES INTERFACE_LINK_OPTIONS "${system_link_options}")
        target_link_directories(${system_lib} INTERFACE "${hot_dir}")
        if (TARGET ${EXECUTABLE_NAME}.elf)
            set_property(TARGET ${EXECUTABLE_NAME}.elf APPEND PROPERTY LINK_DEPENDS "${TOIT_HOT_FLASH_LD}")
        endif()
    endif()

    # The system snapshot and the entry program are compiled in the
    # firmware's format (Kconfig TOIT_BYTECODE_FORMAT_2), independent of the
    # host compiler's default (docs/format2-migration.md, "Devices").
    # Format 2 is trusted (first-party) code: the compiler's default.
    set(DEVICE_COMPILE_ENV ${CMAKE_COMMAND} -E env TOIT_BYTECODE_FORMAT=${TOIT_BYTECODE_FORMAT})

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

    add_custom_command(
            TARGET firmware
            POST_BUILD
            COMMAND ${DEVICE_COMPILE_ENV} ${TOIT} compile --snapshot -O2 -o ${CMAKE_BINARY_DIR}/system.snapshot ${BOOT_PROJECT_ROOT_ARGS} ${BOOT}
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
                    "--bytecode-formats=${TOIT_DEVICE_BYTECODE_FORMATS}"
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
                COMMAND ${DEVICE_COMPILE_ENV} "${TOIT}" compile --snapshot -o "${CMAKE_BINARY_DIR}/program.snapshot" ${ENTRY_PROJECT_ROOT_ARGS} ${RUN_PROGRAM}
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

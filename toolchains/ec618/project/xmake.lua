local TARGET_NAME = "toit"
local LIB_DIR = "$(buildir)/" .. TARGET_NAME .. "/"
local LIB_NAME = "lib" .. TARGET_NAME .. ".a "

-- Path to the Toit VM build output (built by cmake/ninja separately).
local TOIT_BUILD = SDK_TOP .. "/../../build/ec618"

-- Toit-owned build-time configuration header. Force-included here so the
-- PLAT side of the build sees the same CONFIG_TOIT_EC618_* values the
-- CMake build (toolchains/ec618.cmake) has already compiled into
-- libtoit_vm.a.
local TOIT_EC618_CONFIG = SDK_TOP .. "/../../toolchains/ec618/ec618_config.h"

target(TARGET_NAME)
    set_kind("static")
    set_targetdir(LIB_DIR)

    add_includedirs("./inc", {public = true})
    add_includedirs(USER_PROJECT_DIR .. "/src/cmpctmalloc", {public = true})
    add_files("./src/*.c|bsp_custom.c|sys_ro_override.c", {public = true})
    add_cxflags("-include " .. TOIT_EC618_CONFIG, {force = true, public = true})

    -- Link the project's own library.
    LIB_USER = LIB_USER .. SDK_TOP .. "/" .. LIB_DIR .. LIB_NAME .. " "

    -- Link the Toit VM library and mbedTLS libraries — except in the BASE
    -- link (frozen-base phase 4, docs/frozen-base-phase4.md):
    -- TOIT_BASE_LINK=1 links the base alone, with no VM archives; slots
    -- link separately against the resulting base.elf.
    if os.getenv("TOIT_BASE_LINK") ~= "1" then
        LIB_USER = LIB_USER .. TOIT_BUILD .. "/src/libtoit_vm.a "
        LIB_USER = LIB_USER .. TOIT_BUILD .. "/mbedtls/library/libmbedtls.a "
        LIB_USER = LIB_USER .. TOIT_BUILD .. "/mbedtls/library/libmbedx509.a "
        LIB_USER = LIB_USER .. TOIT_BUILD .. "/mbedtls/library/libmbedcrypto.a "
    end
target_end()

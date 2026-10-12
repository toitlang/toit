# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the license in the LICENSE file.

# Each paired case uses the resident agent and checks EC618 health before
# and after capture. Provisioning either board remains a separate action.
set(EC618_BOARD_PORT "$ENV{EC618_BOARD_PORT}" CACHE FILEPATH "Persistent EC618 UART0 console path")
set(EC618_EXPECT_BASE "$ENV{EC618_EXPECT_BASE}" CACHE STRING "Required EC618 base identity")
set(EC618_RIG_LOCK "$ENV{EC618_RIG_LOCK}" CACHE FILEPATH "Shared advisory lock for EC618 rig runners")
include(i2s.cmake)

add_custom_target(check_ec618
    COMMAND "${CMAKE_CTEST_COMMAND}" -C ec618 -L ec618 --output-on-failure
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
    USES_TERMINAL VERBATIM)

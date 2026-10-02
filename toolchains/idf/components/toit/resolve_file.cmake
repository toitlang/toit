# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the GNU Lesser General Public License
# version 2.1, found in the LICENSE file in the repository root.

# Resolves a file or directory path given in the sdkconfig.
# The order of resolution is:
#   1. Absolute path.
#   2. Path relative to the main project directory.
#   3. Path relative to the base directory of Toit.
# The result is always absolute. Build commands run in the binary directory,
# so a path that happens to exist relative to the configure process's working
# directory must not be returned as is.
function(resolve_file out in toit_base_dir warning_text)
    if(IS_ABSOLUTE "${in}")
        set(result "${in}")
    else()
        get_filename_component(result "${in}" ABSOLUTE BASE_DIR "${CMAKE_HOME_DIRECTORY}")
        if(NOT EXISTS "${result}")
            get_filename_component(result "${in}" ABSOLUTE BASE_DIR "${toit_base_dir}")
        endif()
    endif()
    if(NOT EXISTS "${result}" AND warning_text)
        message(WARNING "Missing ${warning_text} file ${in}. Build will fail")
    endif()
    set(${out} "${result}" PARENT_SCOPE)
endfunction()

# Copyright (C) 2021 Toitware ApS.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

function(backtick)
  execute_process(
    COMMAND ${ARGN}
    COMMAND_ERROR_IS_FATAL ANY
  )
endfunction()

set(IN_FILE1 "${INPUT_DIR}/input.toit")
set(IN_FILE2 "${INPUT_DIR}/input2.toit")
set(SOURCE_TRIGGER "${INPUT_DIR}/source.trigger")

file(WRITE ${IN_FILE1} "
import .input2
main:
  print message
")

file(WRITE ${IN_FILE2} "
message := \"hello world\"
")

file(WRITE ${SOURCE_TRIGGER} "
test1
")
backtick(${CMAKE_COMMAND} --build "${BIN_DIR}" --target test_cmake)

file(WRITE ${IN_FILE2} "
message := \"hello world2\"
")
file(WRITE ${SOURCE_TRIGGER} "
test2
")
backtick(${CMAKE_COMMAND} --build "${BIN_DIR}" --target test_cmake)

file(REMOVE ${IN_FILE2})
file(WRITE ${IN_FILE1} "
main:
  print \"compiles after rm\"
")
file(WRITE ${SOURCE_TRIGGER} "
test3
")
backtick(${CMAKE_COMMAND} --build "${BIN_DIR}" --target test_cmake)

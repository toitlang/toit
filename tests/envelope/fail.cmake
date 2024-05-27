# Copyright (C) 2024 Toitware ApS.
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

# Doesn't work on 32 bits yet.
if (NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(TOIT_SKIP_TESTS
    tests/envelope/boot-hello-test.toit
    tests/envelope/boot-upgrade-test.toit
    tests/envelope/firmware-upgrade-test.toit
    tests/envelope/hello-test.toit
  )
endif()

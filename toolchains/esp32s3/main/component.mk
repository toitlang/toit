# Copyright (C) 2019 Toitware ApS.
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

# This is the "main" pseudo-component makefile. It uses the default behaviour
# of compiling all source files in directory, adding 'include' to include path.

LIBTOIT = $(abspath ../../../build/esp32s3/lib/libtoit_image.a ../../../build/esp32s3/lib/libtoit_vm.a)
COMPONENT_ADD_LINKER_DEPS := $(LIBTOIT)
COMPONENT_ADD_LDFLAGS := -lmain -Wl,--whole-archive $(LIBTOIT) -Wl,--no-whole-archive -u toit_patchable_ubjson

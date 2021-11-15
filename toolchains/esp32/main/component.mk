#
# "main" pseudo-component makefile.
#
# (Uses default behaviour of compiling all source files in directory, adding 'include' to include path.)

LIBTOIT = $(abspath ../../../build/esp32/lib/libtoit_image.a ../../../build/esp32/lib/libtoit_vm.a)
COMPONENT_ADD_LINKER_DEPS := $(LIBTOIT)
COMPONENT_ADD_LDFLAGS := -lmain -Wl,--whole-archive $(LIBTOIT) -Wl,--no-whole-archive -u toit_patchable_ubjson

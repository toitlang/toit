# Copyright (C) 2021 Toitware ApS. All rights reserved.

build/esp32/toit.bin build/esp32/toit.elf: build/esp32/lib/libtoit_image.a
	make -C toolchains/esp32/

build/esp32/lib/libtoit_image.a: build/esp32/esp32.image.s build/esp32/CMakeCache.txt
	(cd build/esp32 && ninja toit_image)

.PHONY:	build/host/bin/toitvm build/host/bin/toitc
build/host/bin/toitvm build/host/bin/toitc: build/host/CMakeCache.txt
	(cd build/host && ninja build_toitvm)

.PHONY:	build/ia32/bin/toitvm build/ia32/bin/toitc
build/ia32/bin/toitvm build/ia32/bin/toitc: build/ia32/CMakeCache.txt
	(cd build/ia32 && ninja build_toitvm)

build/host/CMakeCache.txt: build/host/
	(cd build/host && cmake ../.. -G Ninja -DCMAKE_BUILD_TYPE=Release)

build/ia32/CMakeCache.txt: build/ia32/
	(cd build/ia32 && cmake ../.. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/ia32.cmake)

build/esp32/CMakeCache.txt: build/esp32/
	(cd build/esp32 && IMAGE=build/esp32/esp32.image.s cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/esp32/esp32.cmake --no-warn-unused-cli)

build/esp32/esp32.image.s: build/esp32/ build/snapshot build/ia32/bin/toitvm tools/snapshot_to_image.toit
	build/ia32/bin/toitvm tools/snapshot_to_image.toit build/snapshot $@

build/snapshot: build/ia32/bin/toitc examples/hello.toit
	build/ia32/bin/toitc -w $@ examples/hello.toit

build/ia32/ build/host/:
	mkdir -p $@

build/esp32/:
	mkdir -p $@
	make -C toolchains/esp32 -s $(shell pwd)/build/esp32/include/sdkconfig.h

.PHONY:	clean
clean:
	rm -rf build/

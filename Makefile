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

.ONESHELL: # Run all lines of targets in one shell
.SHELLFLAGS += -e

# Use 'make ESP32_ENTRY=examples/mandelbrot.toit esp32' to compile a different
# example for the ESP32 firmware.
ESP32_ENTRY=examples/hello.toit
ESP32_WIFI_SSID=
ESP32_WIFI_PASSWORD=
ESP32_PORT=
ESP32_CHIP=esp32
export IDF_TARGET=$(ESP32_CHIP)
ESP32S3_CHIP=esp32s3
export IDF_TARGET=$(ESP32S3_CHIP)

# Use Toitware ESP-IDF fork by default.
export IDF_PATH ?= $(CURDIR)/third_party/esp-idf

ifeq ($(OS),Windows_NT)
	EXE_SUFFIX=".exe"
	DETECTED_OS=$(OS)
else
	EXE_SUFFIX=
	DETECTED_OS=$(shell uname)
endif

CROSS_ARCH=

prefix ?= /opt/toit-sdk

# HOST
.PHONY: all
all: tools snapshots version-file

check-env:
ifndef IGNORE_SUBMODULE
	@ if git submodule status | grep '^[-+]' ; then \
		echo "Submodules not updated or initialized. Did you 'git submodule update --init --recursive'?"; \
		exit 1; \
	fi
endif
ifndef IGNORE_GIT_TAGS
	@ if [ -z "$$(git rev-list --tags --max-count=1)" ]; then \
		echo "No tags in repository. Checkout is probably shallow. Run 'git fetch --tags --recurse-submodules=no'"; \
		exit 1; \
	fi
endif
ifeq ("$(wildcard $(IDF_PATH)/components/mbedtls/mbedtls/LICENSE)","")
ifeq ("$(IDF_PATH)", "$(CURDIR)/third_party/esp-idf")
	$(error mbedtls sources are missing. Did you `git submodule update --init --recursive`?)
else
	$(error Invalid IDF_PATH. Missing mbedtls sources.)
endif
endif
ifneq ("$(IDF_PATH)", "$(CURDIR)/third_party/esp-idf")
	$(info -- Not using Toitware ESP-IDF fork.)
endif

build/host/CMakeCache.txt:
	$(MAKE) rebuild-cmake

BIN_DIR = build/host/sdk/bin
TOITVM_BIN = $(BIN_DIR)/toit.run$(EXE_SUFFIX)
TOITPKG_BIN = $(BIN_DIR)/toit.pkg$(EXE_SUFFIX)
TOITC_BIN = $(BIN_DIR)/toit.compile$(EXE_SUFFIX)

.PHONY: download-packages
download-packages: check-env build/host/CMakeCache.txt tools
	(cd build/host && ninja download_packages)

.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build/host
	(cd build/host && cmake ../.. -G Ninja -DCMAKE_BUILD_TYPE=Release)

.PHONY: tools
tools: check-env build/host/CMakeCache.txt
	(cd build/host && ninja build_tools)

.PHONY: snapshots
snapshots: tools download-packages
	(cd build/host && ninja build_snapshots)

.PHONY: version-file
version-file: build/host/CMakeCache.txt
	$(MAKE) rebuild-cmake
	(cd build/host && ninja build_version_file)


# CROSS-COMPILE
.PHONY: all-cross
all-cross: tools-cross snapshots-cross version-file-cross

check-env-cross:
ifndef CROSS_ARCH
	$(error invalid must specify a cross-compilation targt with CROSS_ARCH.  For example: make all-cross CROSS_ARCH=riscv64)
endif
ifeq ("$(wildcard ./toolchains/$(CROSS_ARCH).cmake)","")
	$(error invalid cross-compile target '$(CROSS_ARCH)')
endif

build/$(CROSS_ARCH)/CMakeCache.txt:
	$(MAKE) rebuild-cross-cmake

.PHONY: rebuild-cross-cmake
rebuild-cross-cmake:
	mkdir -p build/$(CROSS_ARCH)
	(cd build/$(CROSS_ARCH) && cmake ../../ -G Ninja -DTOITC=$(TOITC_BIN) -DTOITPKG=$(TOITPKG_BIN) -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/$(CROSS_ARCH).cmake --no-warn-unused-cli)

.PHONY: tools-cross
tools-cross: check-env-cross tools build/$(CROSS_ARCH)/CMakeCache.txt
	(cd build/$(CROSS_ARCH) && ninja build_tools)

.PHONY: snapshots-cross
snapshots-cross: tools download-packages build/$(CROSS_ARCH)/CMakeCache.txt
	(cd build/$(CROSS_ARCH) && ninja build_snapshots)

.PHONY: version-file-cross
version-file-cross: build/$(CROSS_ARCH)/CMakeCache.txt
	$(MAKE) rebuild-cross-cmake
	(cd build/host && ninja build_version_file)


# ESP32 VARIANTS
SNAPSHOT_DIR = build/host/sdk/snapshots

ifeq ($(DETECTED_OS), Linux)
	NUM_CPU := $(shell nproc)
else ifeq ($(DETECTED_OS), Darwin)
	NUM_CPU := $(shell sysctl -n hw.ncpu)
else
	# Just assume two cores.
	NUM_CPU := 2
endif

.PHONY: esp32
esp32: check-env build/$(ESP32_CHIP)/toit.bin

build/$(ESP32_CHIP)/toit.bin build/$(ESP32_CHIP)/toit.elf: build/$(ESP32_CHIP)/lib/libtoit_vm.a
build/$(ESP32_CHIP)/toit.bin build/$(ESP32_CHIP)/toit.elf: build/$(ESP32_CHIP)/lib/libtoit_image.a
build/$(ESP32_CHIP)/toit.bin build/$(ESP32_CHIP)/toit.elf: tools snapshots build/config.json
	$(MAKE) -j $(NUM_CPU) -C toolchains/$(ESP32_CHIP)/
	$(TOITVM_BIN) tools/inject_config.toit build/config.json build/$(ESP32_CHIP)/toit.bin

.PHONY: build/$(ESP32_CHIP)/lib/libtoit_vm.a  # Marked phony to force regeneration.
build/$(ESP32_CHIP)/lib/libtoit_vm.a: build/$(ESP32_CHIP)/CMakeCache.txt build/$(ESP32_CHIP)/include/sdkconfig.h
	(cd build/$(ESP32_CHIP) && ninja toit_vm)

build/$(ESP32_CHIP)/lib/libtoit_image.a: build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s build/$(ESP32_CHIP)/CMakeCache.txt build/$(ESP32_CHIP)/include/sdkconfig.h
	(cd build/$(ESP32_CHIP) && ninja toit_image)

build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s: tools snapshots build/snapshot
	mkdir -p build/$(ESP32_CHIP)
	$(TOITVM_BIN) $(SNAPSHOT_DIR)/snapshot_to_image.snapshot build/snapshot $@

.PHONY: build/snapshot  # Marked phony to force regeneration.
build/snapshot: $(TOITC_BIN) $(ESP32_ENTRY)
	$(TOITC_BIN) -w $@ $(ESP32_ENTRY)

build/$(ESP32_CHIP)/CMakeCache.txt:
	mkdir -p build/$(ESP32_CHIP)
	touch build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s
	(cd build/$(ESP32_CHIP) && IMAGE=build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s cmake ../../ -G Ninja -DTOITC=$(TOITC_BIN) -DTOITPKG=$(TOITPKG_BIN) -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/$(ESP32_CHIP)/$(ESP32_CHIP).cmake --no-warn-unused-cli)

build/$(ESP32_CHIP)/include/sdkconfig.h:
	mkdir -p build/$(ESP32_CHIP)
	$(MAKE) -C toolchains/$(ESP32_CHIP) -s "$(CURDIR)"/$@

.PHONY: build/config.json  # Marked phony to force regeneration.
build/config.json:
	echo '{"wifi": {"ssid": "$(ESP32_WIFI_SSID)", "password": "$(ESP32_WIFI_PASSWORD)"}}' > $@


# ESP32 VARIANTS FLASH
.PHONY: flash
flash: check-env-flash esp32
	python $(IDF_PATH)/components/esptool_py/esptool/esptool.py --chip $(ESP32_CHIP) --port $(ESP32_PORT) --baud 921600 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 40m --flash_size detect 0x1000 build/$(ESP32_CHIP)/bootloader/bootloader.bin 0x10000 build/$(ESP32_CHIP)/toit.bin 0x8000 build/$(ESP32_CHIP)/partitions.bin

.PHONY: check-env-flash
check-env-flash:
ifndef ESP32_PORT
	$(error ESP32_PORT is not set)
endif


# UTILITY
.PHONY:	clean
clean:
	rm -rf build/

.PHONY: install-sdk install
install-sdk: all
	install -D --target-directory="$(DESTDIR)$(prefix)"/bin "$(CURDIR)"/build/host/sdk/bin/*
	chmod 644 "$(DESTDIR)$(prefix)"/bin/*.snapshot
	mkdir -p "$(DESTDIR)$(prefix)"/lib
	cp -R "$(CURDIR)"/lib/* "$(DESTDIR)$(prefix)"/lib
	find "$(DESTDIR)$(prefix)"/lib -type f -exec chmod 644 {} \;
	mkdir -p "$(DESTDIR)$(prefix)"/snapshots
	cp "$(CURDIR)"/build/host/sdk/snapshots/* "$(DESTDIR)$(prefix)"/snapshots
	find "$(DESTDIR)$(prefix)"/snapshots -type f -exec chmod 644 {} \;

install: install-sdk


# TESTS (host)
.PHONY: test
test:
	(cd build/host && ninja check_slow check_fuzzer_lib)

.PHONY: update-gold
update-gold:
	(cd build/host && ninja update_gold)
	(cd build/host && ninja update_minus_s_gold)

.PHONY: test-health
test-health: download-packages
	$(MAKE) rebuild-cmake
	(cd build/host && ninja check_health)

.PHONY: update-health-gold
update-health-gold: download-packages
	$(MAKE) rebuild-cmake
	(cd build/host && ninja clear_health_gold)
	(cd build/host && ninja update_health_gold)

.PHONY: download-external
download-external:
	# Download with higher parallelism.
	(cd build/host && ninja -j 16 download_external)

.PHONY: test-external
test-external:
	(cd build/host && ninja check_external)

.PHONY: test-external-health
test-external-health:
	(cd build/host && ninja check_external_health)

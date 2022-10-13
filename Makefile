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
SHELL=bash

# General options.
HOST=host
BUILD_TYPE=Release

# Use 'make flash ESP32_ENTRY=examples/mandelbrot.toit' to flash
# a firmware version with an embedded application.
ESP32_CHIP=esp32
ESP32_PORT=

# The system process is started from its own entry point.
ESP32_SYSTEM_ENTRY=system/extensions/esp32/boot.toit

export IDF_TARGET=$(ESP32_CHIP)

# Use Toitware ESP-IDF fork by default.
export IDF_PATH ?= $(CURDIR)/third_party/esp-idf

ifeq ($(OS),Windows_NT)
	EXE_SUFFIX=.exe
	DETECTED_OS=$(OS)
else
	EXE_SUFFIX=
	DETECTED_OS=$(shell uname)
endif

CROSS_ARCH=

prefix ?= /opt/toit-sdk

# HOST
.PHONY: all
all: sdk

.PHONY: debug
debug:
	LOCAL_CXXFLAGS="-O0" $(MAKE) BUILD_TYPE=Debug

.PHONY: sdk
sdk: tools toit-tools version-file

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
ifeq ('$(wildcard $(IDF_PATH)/components/mbedtls/mbedtls/LICENSE)',"")
ifeq ('$(IDF_PATH)', '$(CURDIR)/third_party/esp-idf')
	$(error mbedtls sources are missing. Did you `git submodule update --init --recursive`?)
else
	$(error Invalid IDF_PATH. Missing mbedtls sources.)
endif
endif
ifneq ('$(IDF_PATH)', '$(CURDIR)/third_party/esp-idf')
	$(info -- Not using Toitware ESP-IDF fork.)
endif

# We mark this phony because adding and removing .cc files means that
# cmake needs to be rerun, but we don't detect that, so it might not
# get run enough.  It takes <1s on Linux to run cmake, so it's
# usually best to run it eagerly.
.PHONY: build/host/CMakeCache.txt
build/$(HOST)/CMakeCache.txt:
	$(MAKE) rebuild-cmake

BIN_DIR = $(CURDIR)/build/$(HOST)/sdk/bin
TOITPKG_BIN = $(BIN_DIR)/toit.pkg$(EXE_SUFFIX)
TOITC_BIN = $(BIN_DIR)/toit.compile$(EXE_SUFFIX)
FIRMWARE_BIN = $(TOIT_TOOLS_DIR)/firmware$(EXE_SUFFIX)

.PHONY: download-packages
download-packages: check-env build/$(HOST)/CMakeCache.txt tools
	(cd build/$(HOST) && ninja download_packages)

.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build/$(HOST)
	(cd build/$(HOST) && cmake ../.. -G Ninja -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -DCMAKE_TOOLCHAIN_FILE=../../toolchains/host.cmake --no-warn-unused-cli)

.PHONY: tools
tools: check-env build/$(HOST)/CMakeCache.txt
	(cd build/$(HOST) && ninja build_tools)

.PHONY: toit-tools
toit-tools: tools download-packages
	(cd build/$(HOST) && ninja build_toit_tools)

.PHONY: version-file
version-file: build/$(HOST)/CMakeCache.txt
	(cd build/$(HOST) && ninja build_version_file)

.PHONY: esptool
esptool: check-env
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) esptool-no-env

.PHONY: esptool-no-env
esptool-no-env:
	pip install -U 'pyinstaller>=4.8'
	pyinstaller --onefile --distpath build/$(HOST)/sdk/tools \
			--workpath build/$(HOST)/esptool \
			--specpath build/$(HOST)/esptool \
			'$(IDF_PATH)/components/esptool_py/esptool/esptool.py'

# CROSS-COMPILE
.PHONY: all-cross
all-cross: tools-cross toit-tools-cross version-file-cross

check-env-cross:
ifndef CROSS_ARCH
	$(error invalid must specify a cross-compilation target with CROSS_ARCH.  For example: make all-cross CROSS_ARCH=riscv64)
endif
ifeq ("$(wildcard ./toolchains/$(CROSS_ARCH).cmake)","")
	$(error invalid cross-compile target '$(CROSS_ARCH)')
endif

.PHONY: build/$(CROSS_ARCH)/CMakeCache.txt
build/$(CROSS_ARCH)/CMakeCache.txt:
	$(MAKE) rebuild-cross-cmake

.PHONY: rebuild-cross-cmake
rebuild-cross-cmake:
	mkdir -p build/$(CROSS_ARCH)
	(cd build/$(CROSS_ARCH) && cmake ../../ -G Ninja -DTOITC=$(TOITC_BIN) -DTOITPKG=$(TOITPKG_BIN) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -DCMAKE_TOOLCHAIN_FILE=../../toolchains/$(CROSS_ARCH).cmake --no-warn-unused-cli)

.PHONY: tools-cross
tools-cross: check-env-cross tools build/$(CROSS_ARCH)/CMakeCache.txt
	(cd build/$(CROSS_ARCH) && ninja build_tools)

.PHONY: toit-tools-cross
toit-tools-cross: tools download-packages build/$(CROSS_ARCH)/CMakeCache.txt
	(cd build/$(CROSS_ARCH) && ninja build_toit_tools)

.PHONY: version-file-cross
version-file-cross: build/$(CROSS_ARCH)/CMakeCache.txt
	(cd build/$(CROSS_ARCH) && ninja build_version_file)

PI_CROSS_ARCH := raspberry_pi

.PHONY: pi-sysroot
pi-sysroot: build/$(PI_CROSS_ARCH)/sysroot/usr

.PHONY: check-env-sysroot
check-env-sysroot:
ifeq ("", "$(shell command -v dpkg)")
	$(error dpkg not in path.)
endif

build/$(PI_CROSS_ARCH)/sysroot/usr: check-env-sysroot
	# This rule is brittle, since it only depends on the 'usr' folder of the sysroot.
	# If the sysroot script fails, it might be incomplete, but another call to
	# the rule won't do anything anymore.
	# Generally we use this rule on the buildbot and are thus not too concerned.
	mkdir -p build/$(PI_CROSS_ARCH)/sysroot
	# The sysroot script doesn't like symlinks in the path. This is why we call 'realpath'.
	third_party/rpi/sysroot.py --distro raspbian --sysroot $$(realpath build/$(PI_CROSS_ARCH)/sysroot) libc6-dev libstdc++-6-dev

.PHONY: pi
pi: pi-sysroot
	$(MAKE) CROSS_ARCH=raspberry_pi SYSROOT="$(CURDIR)/build/$(PI_CROSS_ARCH)/sysroot" all-cross

# ESP32 VARIANTS
.PHONY: check-esp32-env
check-esp32-env:
ifeq ("", "$(shell command -v xtensa-esp32-elf-g++)")
	$(error xtensa-esp32-elf-g++ not in path. Did you `source third_party/esp-idf/export.sh`?)
endif

.PHONY: esp32
esp32:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) esp32-no-env

.PHONY: esp32-no-env
esp32-no-env: check-env check-esp32-env sdk
	IDF_TARGET=$(ESP32_CHIP) idf.py -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" build

# ESP32 MENU CONFIG
.PHONY: menuconfig
menuconfig:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) menuconfig-no-env

.PHONY: menuconfig-no-env
menuconfig-no-env: check-env check-esp32-env
	IDF_TARGET=$(ESP32_CHIP) idf.py -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" menuconfig

.PHONY: flash
flash:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then 'source $(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) flash-no-env

.PHONY: flash-no-env
flash-no-env: esp32-no-env
	IDF_TARGET=$(ESP32_CHIP) idf.py -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" flash monitor

# UTILITY
.PHONY:	clean
clean:
	rm -rf build/
	find toolchains -name sdkconfig | xargs rm

INSTALL_SRC_ARCH := $(HOST)

.PHONY: install-sdk install
install-sdk: all
	install -D --target-directory="$(DESTDIR)$(prefix)"/bin "$(CURDIR)"/build/$(INSTALL_SRC_ARCH)/sdk/bin/*
	install -D --target-directory="$(DESTDIR)$(prefix)"/tools "$(CURDIR)"/build/$(INSTALL_SRC_ARCH)/sdk/tools/*
	mkdir -p "$(DESTDIR)$(prefix)"/lib
	cp -R "$(CURDIR)"/lib/* "$(DESTDIR)$(prefix)"/lib
	find "$(DESTDIR)$(prefix)"/lib -type f -exec chmod 644 {} \;

install: install-sdk


# TESTS (host)
.PHONY: test
test:
	(cd build/$(HOST) && ninja check_slow check_fuzzer_lib)

.PHONY: update-gold
update-gold:
	$(MAKE) rebuild-cmake
	(cd build/$(HOST) && ninja update_gold)
	(cd build/$(HOST) && ninja update_minus_s_gold)

.PHONY: test-health
test-health: download-packages
	$(MAKE) rebuild-cmake
	(cd build/$(HOST) && ninja check_health)

.PHONY: update-health-gold
update-health-gold: download-packages
	$(MAKE) rebuild-cmake
	(cd build/$(HOST) && ninja clear_health_gold)
	(cd build/$(HOST) && ninja update_health_gold)

.PHONY: enable-external
enable-external:
	$(MAKE) rebuild-cmake  # Ensure the cmake-directory was created.
	cmake -DTOIT_TEST_EXTERNAL=ON build/$(HOST)
	$(MAKE) download-external
	$(MAKE) rebuild-cmake
	$(MAKE) download-packages

.PHONY: check-external-enabled
check-external-enabled:
	@ if ! cmake -LA -N build/$(HOST) | grep 'TOIT_TEST_EXTERNAL:BOOL=ON'; then \
		echo "external projects are not enabled. Run 'make enable-external' first."; \
		exit 1; \
	fi

.PHONY: disable-external
disable-external: check-external-enabled
	$(MAKE) rebuild-cmake  # Ensure the cmake-directory was created.
	cmake -DTOIT_TEST_EXTERNAL=OFF build/$(HOST)

.PHONY: download-external
download-external: check-external-enabled
	# Download with higher parallelism.
	(cd build/$(HOST) && ninja -j 16 download_external)

.PHONY: test-external
test-external: check-external-enabled
	(cd build/$(HOST) && ninja check_external)

.PHONY: test-external-health
test-external-health: check-external-enabled
	(cd build/$(HOST) && ninja check_external_health)

.PHONY: update-external-health-gold
update-external-health-gold: download-packages check-external-enabled
	$(MAKE) rebuild-cmake
	(cd build/$(HOST) && ninja clear_external_health_gold)
	(cd build/$(HOST) && ninja update_external_health_gold)

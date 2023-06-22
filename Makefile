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
TARGET ?= $(HOST)
TOOLCHAIN ?= $(TARGET)

prefix ?= /opt/toit-sdk

# Use 'make flash ESP32_ENTRY=examples/mandelbrot.toit' to flash
# a firmware version with an embedded application.
ESP32_CHIP=esp32
ESP32_PORT=

# The system process is started from its own entry point.
ESP32_SYSTEM_ENTRY=system/extensions/esp32/boot.toit

ifeq ($(ESP32_CHIP),esp32s3-spiram-octo)
	IDF_TARGET=esp32s3
else
	IDF_TARGET=$(ESP32_CHIP)
endif
export IDF_TARGET

# Use Toitware ESP-IDF fork by default.
export IDF_PATH ?= $(CURDIR)/third_party/esp-idf

ifeq ($(OS),Windows_NT)
	EXE_SUFFIX=.exe
	DETECTED_OS=$(OS)
else
	EXE_SUFFIX=
	DETECTED_OS=$(shell uname)
endif

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
ifneq ('$(realpath $(IDF_PATH))', '$(realpath $(CURDIR)/third_party/esp-idf)')
	$(info -- Not using Toitware ESP-IDF fork.)
endif
ifeq ("$(wildcard ./toolchains/$(TOOLCHAIN).cmake)","")
	$(error invalid compilation target '$(TOOLCHAIN)')
endif

# We mark this phony because adding and removing .cc files means that
# cmake needs to be rerun, but we don't detect that, so it might not
# get run enough.  It takes <1s on Linux to run cmake, so it's
# usually best to run it eagerly.
.PHONY: build/$(TARGET)/CMakeCache.txt
build/$(TARGET)/CMakeCache.txt:
	$(MAKE) rebuild-cmake

ifneq ($(TARGET),$(HOST))
# Support for cross-compilation.

.PHONY: build/$(HOST)/CMakeCache.txt
build/$(HOST)/CMakeCache.txt:
	$(MAKE) TARGET=$(HOST) rebuild-cmake

.PHONY: sysroot
sysroot: check-env
	$(MAKE) build/$(TARGET)/sysroot/usr
endif

BIN_DIR = $(CURDIR)/build/$(HOST)/sdk/bin
TOITPKG_BIN = $(BIN_DIR)/toit.pkg$(EXE_SUFFIX)
TOITC_BIN = $(BIN_DIR)/toit.compile$(EXE_SUFFIX)
FIRMWARE_BIN = $(TOIT_TOOLS_DIR)/firmware$(EXE_SUFFIX)

.PHONY: download-packages
download-packages: check-env build/$(HOST)/CMakeCache.txt tools
	(cd build/$(HOST) && ninja download_packages)

.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p build/$(TARGET)
	(cd build/$(TARGET) && cmake ../../ -G Ninja -DTOITC=$(TOITC_BIN) -DTOITPKG=$(TOITPKG_BIN) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -DCMAKE_TOOLCHAIN_FILE=../../toolchains/$(TOOLCHAIN).cmake --no-warn-unused-cli)

.PHONY: host-tools
host-tools: check-env build/$(HOST)/CMakeCache.txt
	(cd build/$(HOST) && ninja build_tools)

.PHONY: tools
# This rule contains a reference to host-tools.
# This means that on host we will try to build host twice, but
# the second attempt will be a no-op.
tools: host-tools check-env build/$(TARGET)/CMakeCache.txt
	(cd build/$(TARGET) && ninja build_tools)

.PHONY: toit-tools
toit-tools: tools download-packages
	(cd build/$(TARGET) && ninja build_toit_tools)

.PHONY: vessels
vessels: check-env build/$(TARGET)/CMakeCache.txt
	(cd build/$(TARGET) && ninja build_vessels)

.PHONY: version-file
version-file: build/$(TARGET)/CMakeCache.txt
	(cd build/$(TARGET) && ninja build_version_file)


.PHONY: pi
pi: raspbian

TOITLANG_SYSROOTS := armv7 aarch64 riscv64 raspbian arm-linux-gnueabi
ifneq (,$(filter $(TARGET),$(TOITLANG_SYSROOTS)))
SYSROOT_URL=https://github.com/toitlang/sysroots/releases/download/v1.3.0/sysroot-$(TARGET).tar.gz

rebuild-cmake: sysroot

build/$(TARGET)/sysroot/sysroot.tar.xz:
	if [[ "$(SYSROOT_URL)" == "" ]]; then \
		echo "No sysroot URL for $(TARGET)"; \
		exit 1; \
	fi

	mkdir -p build/$(TARGET)/sysroot
	curl --location --output build/$(TARGET)/sysroot/sysroot.tar.xz $(SYSROOT_URL)

build/$(TARGET)/sysroot/usr: build/$(TARGET)/sysroot/sysroot.tar.xz
	tar x -f build/$(TARGET)/sysroot/sysroot.tar.xz -C build/$(TARGET)/sysroot
	touch $@
endif

# Create convenience rules for armv7, aarch64 and riscv64.
define CROSS_RULE
.PHONY: $(1)
$(1):
	$(MAKE) TARGET=$(1) sdk
endef

$(foreach arch,$(TOITLANG_SYSROOTS),$(eval $(call CROSS_RULE,$(arch))))

# ESP32 VARIANTS
.PHONY: check-esp32-env
check-esp32-env:
ifeq ("", "$(shell command -v xtensa-esp32-elf-g++)")
	$(error xtensa-esp32-elf-g++ not in path. Did you `source third_party/esp-idf/export.sh`?)
endif

IDF_PY ::= "$(IDF_PATH)/tools/idf.py"

.PHONY: esp32
esp32:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) esp32-no-env

.PHONY: esp32-no-env
esp32-no-env: check-env check-esp32-env sdk
	cmake -E env IDF_TARGET=$(IDF_TARGET) IDF_CCACHE_ENABLE=1 python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" build

# ESP32 MENU CONFIG
.PHONY: menuconfig
menuconfig:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) menuconfig-no-env

.PHONY: menuconfig-no-env
menuconfig-no-env: check-env check-esp32-env
	cmake -E env IDF_TARGET=$(IDF_TARGET) python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" menuconfig

.PHONY: flash
flash:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) flash-no-env

.PHONY: flash-no-env
flash-no-env: esp32-no-env
	cmake -E env IDF_TARGET=$(IDF_TARGET) python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" flash monitor

# UTILITY
.PHONY:	clean
clean:
	rm -rf build/
	find toolchains -name sdkconfig -exec rm '{}' ';'

INSTALL_SRC_ARCH := $(TARGET)

.PHONY: install-sdk install
install-sdk:
	install -D --target-directory="$(DESTDIR)$(prefix)"/bin "$(CURDIR)"/build/$(INSTALL_SRC_ARCH)/sdk/bin/*
	install -D --target-directory="$(DESTDIR)$(prefix)"/tools "$(CURDIR)"/build/$(INSTALL_SRC_ARCH)/sdk/tools/*
	install -D --target-directory="$(DESTDIR)$(prefix)"/vessels "$(CURDIR)"/build/$(INSTALL_SRC_ARCH)/sdk/vessels/*
	mkdir -p "$(DESTDIR)$(prefix)"/lib
	cp -R "$(CURDIR)"/lib/* "$(DESTDIR)$(prefix)"/lib
	find "$(DESTDIR)$(prefix)"/lib -type f -exec chmod 644 {} \;

install: install-sdk


# TESTS (host)
.PHONY: test
test:
	(cd build/$(HOST) && ninja check_slow check_fuzzer_lib)

.PHONY: test-fast
test-fast:
	(cd build/$(HOST) && ninja check)

.PHONY: update-gold
update-gold:
	$(MAKE) rebuild-cmake
	(cd build/$(HOST) && ninja update_gold)
	(cd build/$(HOST) && ninja update_minus_s_gold)
	(cd build/$(HOST) && ninja update_type_gold)

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

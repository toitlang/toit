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
BUILD ?= build
HOST ?= host
BUILD_TYPE ?= Release
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
else ifeq ($(ESP32_CHIP),esp32-eth-clk-out17)
	IDF_TARGET=esp32
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
all: sdk build-test-assets

.PHONY: debug
debug:
	cmake -E env LOCAL_CFLAGS="-O0" LOCAL_CXXFLAGS="-O0" $(MAKE) BUILD_TYPE=Debug

.PHONY: sdk
sdk: tools toit-tools version-file

# Rebuilds the SDK using only Ninja, without rebuilding the
# Ninja files with Cmake.
.PHONY: sdk-no-cmake
sdk-no-cmake: tools-no-cmake toit-tools-no-cmake

.PHONY: check-env
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

.PHONY: check-mbedtls-config
check-mbedtls-config: check-env
	@ if ! diff -q --ignore-all-space third_party/esp-idf/components/mbedtls/mbedtls/include/mbedtls/mbedtls_config.h mbedtls/include/default_config.h; then \
		echo "mbedtls/include/default_config.h is not in sync with third_party/esp-idf/components/mbedtls/mbedtls/include/mbedtls/mbedtls_config.h"; \
		echo "See the mbedtls/include/README.md for instructions on how to update mbedtls/include/default_config.h"; \
		exit 1; \
	fi

# We mark this phony because adding and removing .cc files means that
# cmake needs to be rerun, but we don't detect that, so it might not
# get run enough.  It takes <1s on Linux to run cmake, so it's
# usually best to run it eagerly.
.PHONY: $(BUILD)/$(TARGET)/CMakeCache.txt
$(BUILD)/$(TARGET)/CMakeCache.txt:
	$(MAKE) rebuild-cmake

ifneq ($(TARGET),$(HOST))
# Support for cross-compilation.

.PHONY: $(BUILD)/$(HOST)/CMakeCache.txt
$(BUILD)/$(HOST)/CMakeCache.txt:
	$(MAKE) TARGET=$(HOST) rebuild-cmake

.PHONY: sysroot
sysroot: check-env
	$(MAKE) $(BUILD)/$(TARGET)/sysroot/usr
endif

BIN_DIR = $(abspath $(BUILD)/$(HOST)/sdk/bin)
TOIT_BIN = $(BIN_DIR)/toit$(EXE_SUFFIX)
FIRMWARE_BIN = $(TOIT_TOOLS_DIR)/firmware$(EXE_SUFFIX)

.PHONY: download-packages
download-packages: check-env $(BUILD)/$(TARGET)/CMakeCache.txt host-tools
	(cd $(BUILD)/$(TARGET) && ninja download_packages)

.PHONY: rebuild-cmake
rebuild-cmake:
	mkdir -p $(BUILD)/$(TARGET)
	(cd $(BUILD)/$(TARGET) && cmake $(CURDIR) -G Ninja -DHOST_TOIT=$(TOIT_BIN) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -DCMAKE_TOOLCHAIN_FILE=$(CURDIR)/toolchains/$(TOOLCHAIN).cmake --no-warn-unused-cli)

.PHONY: sync
sync: sync-packages
	git submodule update --init --recursive

.PHONY: sync-packages
sync-packages: check-env $(BUILD)/$(TARGET)/CMakeCache.txt host-tools
	(cd $(BUILD)/$(TARGET) && ninja sync_packages)

.PHONY: disable-auto-sync
disable-auto-sync:
	$(MAKE) rebuild-cmake
	cmake -DTOIT_PKG_AUTO_SYNC=OFF $(BUILD)/$(TARGET)

.PHONY: enable-lto
enable-lto:
	$(MAKE) rebuild-cmake  # Ensure the cmake-directory was created.
	cmake -DENABLE_LTO=ON $(BUILD)/$(HOST)


.PHONY: host-tools
host-tools: check-mbedtls-config check-env $(BUILD)/$(HOST)/CMakeCache.txt
	(cd $(BUILD)/$(HOST) && ninja build_tools)

.PHONY: tools
# This rule contains a reference to host-tools.
# This means that on host we will try to build host twice, but
# the second attempt will be a no-op.
tools: host-tools check-env $(BUILD)/$(TARGET)/CMakeCache.txt tools-no-cmake
	(cd $(BUILD)/$(TARGET) && ninja build_tools)

.PHONY: build-envelope
build-envelope: download-packages
	(cd $(BUILD)/$(TARGET) && ninja build_envelope)

.PHONY: tools-no-cmake
tools-no-cmake:
	(cd $(BUILD)/$(TARGET) && ninja build_tools)

.PHONY: toit-tools
toit-tools: tools download-packages
	(cd $(BUILD)/$(TARGET) && ninja build_toit_tools)

.PHONY: toit-tools-no-cmake
toit-tools-no-cmake:
	(cd $(BUILD)/$(TARGET) && ninja build_toit_tools)

.PHONY: vessels
vessels: check-env $(BUILD)/$(TARGET)/CMakeCache.txt
	(cd $(BUILD)/$(TARGET) && ninja build_vessels)

.PHONY: version-file
version-file: $(BUILD)/$(TARGET)/CMakeCache.txt
	(cd $(BUILD)/$(TARGET) && ninja build_version_file)


.PHONY: pi
pi: raspbian

TOITLANG_SYSROOTS := armv7 aarch64 raspbian arm-linux-gnueabi
ifneq (,$(filter $(TARGET),$(TOITLANG_SYSROOTS)))
SYSROOT_URL=https://github.com/toitlang/sysroots/releases/download/v1.3.0/sysroot-$(TARGET).tar.gz

rebuild-cmake: sysroot

$(BUILD)/$(TARGET)/sysroot/sysroot.tar.xz:
	if [[ "$(SYSROOT_URL)" == "" ]]; then \
		echo "No sysroot URL for $(TARGET)"; \
		exit 1; \
	fi

	mkdir -p $(BUILD)/$(TARGET)/sysroot
	curl --location --output $(BUILD)/$(TARGET)/sysroot/sysroot.tar.xz $(SYSROOT_URL)

$(BUILD)/$(TARGET)/sysroot/usr: $(BUILD)/$(TARGET)/sysroot/sysroot.tar.xz
	tar x -f $(BUILD)/$(TARGET)/sysroot/sysroot.tar.xz -C $(BUILD)/$(TARGET)/sysroot
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

IDF_PY := "$(IDF_PATH)/tools/idf.py"

.PHONY: esp32
esp32:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) esp32-no-env

.PHONY: esp32-no-env
esp32-no-env: check-env check-esp32-env sdk
	cmake -E env IDF_TARGET=$(IDF_TARGET) IDF_CCACHE_ENABLE=1 python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B $(BUILD)/$(ESP32_CHIP) -p "$(ESP32_PORT)" build

# ESP32 MENU CONFIG
.PHONY: menuconfig
menuconfig:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) menuconfig-no-env

.PHONY: menuconfig-no-env
menuconfig-no-env: check-env check-esp32-env
	cmake -E env IDF_TARGET=$(IDF_TARGET) python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B $(BUILD)/$(ESP32_CHIP) menuconfig
	cmake -E env IDF_TARGET=$(IDF_TARGET) python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B $(BUILD)/$(ESP32_CHIP) save-defconfig

# ESP32 MENU CONFIG
.PHONY: size-components
size-components:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) size-components-no-env

.PHONY: size-components-no-env
size-components-no-env: check-env check-esp32-env
	cmake -E env IDF_TARGET=$(IDF_TARGET) python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B build/$(ESP32_CHIP) -p "$(ESP32_PORT)" size-components

.PHONY: flash
flash:
	if [ "$(shell command -v xtensa-esp32-elf-g++)" = "" ]; then source '$(IDF_PATH)/export.sh'; fi; \
	    $(MAKE) flash-no-env

.PHONY: flash-no-env
flash-no-env: esp32-no-env
	cmake -E env IDF_TARGET=$(IDF_TARGET) python$(EXE_SUFFIX) $(IDF_PY) -C toolchains/$(ESP32_CHIP) -B $(BUILD)/$(ESP32_CHIP) -p "$(ESP32_PORT)" flash monitor

# UTILITY
.PHONY:	clean
clean:
	rm -rf $(BUILD)/

INSTALL_SRC_ARCH := $(TARGET)

.PHONY: install-sdk install
install-sdk:
	mkdir -p "$(DESTDIR)$(prefix)"/bin
	mkdir -p "$(DESTDIR)$(prefix)"/tools
	mkdir -p "$(DESTDIR)$(prefix)"/vessels
	for f in "$(BUILD)"/$(INSTALL_SRC_ARCH)/sdk/bin/*; do \
		install -m 755 "$$f" "$(DESTDIR)$(prefix)"/bin; \
	done
	for f in "$(BUILD)"/$(INSTALL_SRC_ARCH)/sdk/tools/*; do \
		install -m 755 "$$f" "$(DESTDIR)$(prefix)"/tools; \
	done
	for f in "$(BUILD)"/$(INSTALL_SRC_ARCH)/sdk/vessels/*; do \
		install -m 755 "$$f" "$(DESTDIR)$(prefix)"/vessels; \
	done
	mkdir -p "$(DESTDIR)$(prefix)"/lib
	cp -R "$(CURDIR)"/lib/* "$(DESTDIR)$(prefix)"/lib
	find "$(DESTDIR)$(prefix)"/lib -type f -exec chmod 644 {} \;

install: install-sdk


# TESTS (host)
.PHONY: test
test:
	(cd $(BUILD)/$(HOST) && ninja check_slow check_fuzzer_lib)

.PHONY: test-serial
test-serial:
	@if [ -z "$$TOIT_EXE_HW" ]; then \
		echo "TOIT_EXE_HW is not set."; \
		exit 1; \
	fi
	mkdir -p $(BUILD)/serial
	(cd $(BUILD)/serial && cmake -DTOIT_EXE_HW=$$TOIT_EXE_HW -G Ninja $(CURDIR)/tests/hw)
	$$TOIT_EXE_HW pkg install --project-root tests/hw/pi
	(cd $(BUILD)/serial && ninja check_pi)

.PHONY: build-test-assets
build-test-assets: rebuild-cmake
	(cd $(BUILD)/$(HOST) && ninja build_test_assets)

.PHONY: test-flaky
test-flaky:
	(cd $(BUILD)/$(HOST) && ninja check_flaky)

.PHONY: test-fast
test-fast:
	(cd $(BUILD)/$(HOST) && ninja check)

.PHONY: update-gold
update-gold:
	$(MAKE) rebuild-cmake
	(cd $(BUILD)/$(HOST) && ninja update_gold)
	(cd $(BUILD)/$(HOST) && ninja update_pkg_gold)
	(cd $(BUILD)/$(HOST) && ninja update_minus_s_gold)
	(cd $(BUILD)/$(HOST) && ninja update_type_gold)

.PHONY: test-health
test-health: download-packages
	$(MAKE) rebuild-cmake
	(cd $(BUILD)/$(HOST) && ninja check_health)

.PHONY: update-health-gold
update-health-gold: download-packages
	$(MAKE) rebuild-cmake
	(cd $(BUILD)/$(HOST) && ninja clear_health_gold)
	(cd $(BUILD)/$(HOST) && ninja update_health_gold)

.PHONY: enable-external
enable-external:
	$(MAKE) rebuild-cmake  # Ensure the cmake-directory was created.
	cmake -DTOIT_TEST_EXTERNAL=ON $(BUILD)/$(HOST)
	$(MAKE) download-external
	$(MAKE) rebuild-cmake
	$(MAKE) download-packages

.PHONY: check-external-enabled
check-external-enabled:
	@ if ! cmake -LA -N $(BUILD)/$(HOST) | grep 'TOIT_TEST_EXTERNAL:BOOL=ON'; then \
		echo "external projects are not enabled. Run 'make enable-external' first."; \
		exit 1; \
	fi

.PHONY: disable-external
disable-external: check-external-enabled
	$(MAKE) rebuild-cmake  # Ensure the cmake-directory was created.
	cmake -DTOIT_TEST_EXTERNAL=OFF $(BUILD)/$(HOST)

.PHONY: download-external
download-external: check-external-enabled
	# Download with higher parallelism.
	(cd $(BUILD)/$(HOST) && ninja -j 16 download_external)

.PHONY: test-external
test-external: check-external-enabled
	(cd $(BUILD)/$(HOST) && ninja check_external)

.PHONY: test-external-health
test-external-health: check-external-enabled
	(cd $(BUILD)/$(HOST) && ninja check_external_health)

.PHONY: update-external-health-gold
update-external-health-gold: download-packages check-external-enabled
	$(MAKE) rebuild-cmake
	(cd $(BUILD)/$(HOST) && ninja clear_external_health_gold)
	(cd $(BUILD)/$(HOST) && ninja update_external_health_gold)

.PHONY: update-pkgs
update-pkgs:
	for d in $$(git ls-files | grep package.yaml | grep -v tests/pkg | grep -v tests/lsp/project-root-multi); do \
	  toit pkg update --project-root $$(dirname $$d); \
	done

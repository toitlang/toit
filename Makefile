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
.NOTPARALLEL:
.SHELLFLAGS += -e
SHELL=bash

# General options.
BUILD ?= build
HOST ?= host
BUILD_TYPE ?= Release
TARGET ?= $(HOST)
TOOLCHAIN ?= $(TARGET)

prefix ?= /usr

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

# If the user has not set the IGNORE_SUBMODULE variable, we check if a
# version.cmake file exists. If it does, then we assume that this is a
# tarball and that we should not do the check.
ifeq ($(origin IGNORE_SUBMODULE), undefined)
  ifneq ("$(wildcard version.cmake)", "")
    IGNORE_SUBMODULE := 1
  endif
endif

# Same for IGNORE_GIT_TAGS.
ifeq ($(origin IGNORE_GIT_TAGS), undefined)
	ifneq ("$(wildcard version.cmake)", "")
		IGNORE_GIT_TAGS := 1
	endif
endif

.PHONY: all
all: sdk build-test-assets

.PHONY: debug
debug:
	cmake -E env LOCAL_CFLAGS="-O0" LOCAL_CXXFLAGS="-O0" $(MAKE) BUILD_TYPE=Debug

.PHONY: sdk
sdk: tools version-file

# Rebuilds the SDK using only Ninja, without rebuilding the
# Ninja files with Cmake.
.PHONY: sdk-no-cmake
sdk-no-cmake: tools-no-cmake

.PHONY: check-env
check-env:
ifndef IGNORE_SUBMODULE
	@ if git submodule status | grep '^[-+]' ; then \
		echo "Submodules not updated or initialized. Did you 'git submodule update --init --recursive'?"; \
		echo "You can disable this check by setting IGNORE_SUBMODULE=1"; \
		exit 1; \
	fi
endif
ifndef IGNORE_GIT_TAGS
	@ if [ -z "$$(git rev-list --tags --max-count=1)" ]; then \
		echo "No tags in repository. Checkout is probably shallow. Run 'git fetch --tags --recurse-submodules=no'"; \
		echo "You can disable this check by setting IGNORE_GIT_TAGS=1"; \
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

$(BUILD)/$(TARGET)/CMakeCache.txt:
	$(MAKE) rebuild-cmake

ifneq ($(TARGET),$(HOST))
# Support for cross-compilation.

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

.PHONY: download-bootstrap-packages
download-bootstrap-packages: check-env $(BUILD)/$(TARGET)/CMakeCache.txt
	(cd $(BUILD)/$(TARGET) && ninja download_embedded_program_packages)

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
disable-auto-sync: $(BUILD)/$(TARGET)/CMakeCache.txt
	cmake -DTOIT_PKG_AUTO_SYNC=OFF $(BUILD)/$(TARGET)

.PHONY: enable-lto
enable-lto: $(BUILD)/$(HOST)/CMakeCache.txt
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

.PHONY: vessels
vessels: check-env $(BUILD)/$(TARGET)/CMakeCache.txt
	(cd $(BUILD)/$(TARGET) && ninja build_vessels)

.PHONY: version-file
version-file: $(BUILD)/$(TARGET)/CMakeCache.txt
	(cd $(BUILD)/$(TARGET) && ninja build_version_file)


.PHONY: pi
pi: raspbian

TOITLANG_SYSROOTS := armv7 aarch64 raspbian riscv64 arm-linux-gnueabi
ifneq (,$(filter $(TARGET),$(TOITLANG_SYSROOTS)))
SYSROOT_URL=https://github.com/toitlang/sysroots/releases/download/v1.6.0/sysroot-$(TARGET).tar.gz

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

# EC618
EC618_SDK = $(CURDIR)/third_party/luatos-soc-ec618
EC618_GCC_PATH ?= $(HOME)/.xmake/packages/g/gnu_rm/2021.10/69b9a9c7bd56401fb164f28701b1431e
EC618_SYSTEM_ENTRY = $(CURDIR)/system/extensions/ec618/boot.toit
EC618_ENVELOPE = $(BUILD)/ec618/firmware.envelope
EC618_BINPKG = $(BUILD)/ec618/toit.binpkg

.PHONY: ec618
ec618: check-env host-tools
	# Build the EC618 VM library.
	mkdir -p $(BUILD)/ec618
	(cd $(BUILD)/ec618 && cmake $(CURDIR) -G Ninja -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -DCMAKE_TOOLCHAIN_FILE=$(CURDIR)/toolchains/ec618.cmake --no-warn-unused-cli)
	(cd $(BUILD)/ec618 && ninja toit_vm mbedtls mbedx509 mbedcrypto)
	# Build the slot-A firmware (bootloader + AP + CP) via xmake.
	cd $(EC618_SDK) && rm -rf build && \
		GCC_PATH=$(EC618_GCC_PATH) PROJECT_NAME=toit xmake config -p cross -y && \
		GCC_PATH=$(EC618_GCC_PATH) PROJECT_NAME=toit xmake build
	cd $(CURDIR)
	# Verify the slot-A VM image is position-independent (every VM->PLAT call
	# goes through the jump table) — required for the relocate-on-write OTA.
	$(TOIT_BIN) run --project-root tools tools/ec618/check-slot-pic.toit -- \
		--objdump=$(EC618_GCC_PATH)/bin/arm-none-eabi-objdump \
		--nm=$(EC618_GCC_PATH)/bin/arm-none-eabi-nm \
		$(EC618_SDK)/build/toit/toit.elf
	# Save the slot-A artifacts: the envelope is built from these, and the
	# slot-B relink below overwrites build/toit.
	cp $(EC618_SDK)/build/toit/toit.elf $(BUILD)/ec618/toit-slot-a.elf
	cp $(EC618_SDK)/build/toit/ap.bin $(BUILD)/ec618/ap-slot-a.bin
	# Re-link slot B (linker script only, a fast re-link) as an independent
	# byte-identity oracle for the relocation table.
	cd $(EC618_SDK) && rm -f build/toit/toit.elf build/toit/ap.bin build/toit/toit.bin && \
		TOIT_VM_SLOT_B=1 GCC_PATH=$(EC618_GCC_PATH) PROJECT_NAME=toit xmake build
	cd $(CURDIR)
	cp $(EC618_SDK)/build/toit/ap.bin $(BUILD)/ec618/ap-slot-b.bin
	# Build + verify the dual-slot relocation table. gen-slot-reloc relocates
	# the slot-A image to slot B and proves byte-identity with the slot-B link
	# — the guard that no --emit-relocs relocation was dropped. Runs BEFORE the
	# envelope so the bundled extension can be placed inside the VM slot and
	# relocated with the VM body (carried into the envelope via --reloc.bin).
	$(TOIT_BIN) run --project-root tools tools/ec618/gen-slot-reloc.toit -- \
		--readelf=$(EC618_GCC_PATH)/bin/arm-none-eabi-readelf \
		--nm=$(EC618_GCC_PATH)/bin/arm-none-eabi-nm \
		--elf=$(BUILD)/ec618/toit-slot-a.elf \
		--ap=$(BUILD)/ec618/ap-slot-a.bin \
		--out=$(BUILD)/ec618/slot-reloc.bin \
		--verify-slot-b=$(BUILD)/ec618/ap-slot-b.bin
	# Prove the DEVICE relocator (src/slot_reloc_ec618.cc — the C++ that runs
	# on the chip): relocate slot A == slot B and un-relocate slot B == slot A,
	# both whole-body and sector-chunked.
	$(CXX) -Wall -Wextra -O2 -I src tools/slot_reloc_test/test.cc src/slot_reloc_ec618.cc -o $(BUILD)/ec618/slot_reloc_test
	$(BUILD)/ec618/slot_reloc_test $(BUILD)/ec618/ap-slot-a.bin $(BUILD)/ec618/ap-slot-b.bin $(BUILD)/ec618/slot-reloc.bin
	# Compile the system snapshot.
	$(TOIT_BIN) compile --snapshot -o $(BUILD)/ec618/system.snapshot $(EC618_SYSTEM_ENTRY)
	# Create the firmware envelope from the slot-A AP image + matching CP + the
	# reloc table (which moves the bundled extension inside the VM slot).
	rm -f $(EC618_ENVELOPE)
	$(TOIT_BIN) tool firmware -e $(EC618_ENVELOPE) create ec618 \
		--firmware.bin $(BUILD)/ec618/ap-slot-a.bin \
		--cp.bin $(EC618_SDK)/PLAT/prebuild/FW/lib/cp-demo-flash.bin \
		--reloc.bin $(BUILD)/ec618/slot-reloc.bin \
		--system.snapshot $(BUILD)/ec618/system.snapshot
	# Extract the binpkg (the extension now lives inside slot A).
	$(TOIT_BIN) tool firmware -e $(EC618_ENVELOPE) extract -o $(EC618_BINPKG) --format image
	@echo "Envelope: $(EC618_ENVELOPE)"
	@echo "Binpkg:   $(EC618_BINPKG)"
	@echo "Reloc:    $(BUILD)/ec618/slot-reloc.bin"

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

.PHONY: esp32c3
esp32c3:
	$(MAKE) IDF_TARGET=esp32c3 ESP32_CHIP=esp32c3 esp32

.PHONY: esp32c6
esp32c6:
	$(MAKE) IDF_TARGET=esp32c6 ESP32_CHIP=esp32c6 esp32

.PHONY: esp32s2
esp32s2:
	$(MAKE) IDF_TARGET=esp32s2 ESP32_CHIP=esp32s2 esp32

.PHONY: esp32s3
esp32s3:
	$(MAKE) IDF_TARGET=esp32s3 ESP32_CHIP=esp32s3 esp32

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
	# The DESTDIR is passed as environment variable and picked up by cmake.
	cmake --install "$(BUILD)/$(TARGET)" --prefix "$(prefix)"

install: install-sdk


# TESTS (host)
.PHONY: test
test: rebuild-cmake
	(cd $(BUILD)/$(HOST) && ninja check_slow check_fuzzer_lib)

.PHONY: rebuild-cmake-hw
rebuild-cmake-hw:
	@if [ -z "$$TOIT_EXE_HW" ]; then \
		echo "TOIT_EXE_HW is not set."; \
		exit 1; \
	fi
	mkdir -p $(BUILD)/hw
	rm -f $(BUILD)/hw/CMakeCache.txt
	(cd $(BUILD)/hw && cmake -DTOIT_EXE_HW=$$TOIT_EXE_HW -G Ninja $(CURDIR)/tests/hw)

.PHONY: download-packages-hw-host
download-packages-hw-host:
	cmake -E env TOIT_EXE_HW=$(BUILD)/$(HOST)/sdk/bin/toit $(MAKE) download-packages-hw

.PHONY: download-packages-hw
download-packages-hw:
	$$TOIT_EXE_HW pkg install --project-root tests/hw/pi
	$$TOIT_EXE_HW pkg install --project-root tests/hw/esp32
	$$TOIT_EXE_HW pkg install --project-root tests/hw/esp-tester

.PHONY: test-hw
test-hw: rebuild-cmake-hw download-packages-hw
	(cd $(BUILD)/hw && ninja check_hw)

.PHONY: build-test-assets
build-test-assets: $(BUILD)/$(HOST)/CMakeCache.txt
	(cd $(BUILD)/$(HOST) && ninja build_test_assets)

.PHONY: test-flaky
test-flaky:
	(cd $(BUILD)/$(HOST) && ninja check_flaky)

.PHONY: test-fast
test-fast:
	(cd $(BUILD)/$(HOST) && ninja check)

.PHONY: update-gold
update-gold:
	(cd $(BUILD)/$(HOST) && ninja update_gold)
	(cd $(BUILD)/$(HOST) && ninja update_pkg_gold)
	(cd $(BUILD)/$(HOST) && ninja update_minus_s_gold)
	(cd $(BUILD)/$(HOST) && ninja update_type_gold)

.PHONY: test-health
test-health: download-packages download-packages-hw-host
	(cd $(BUILD)/$(HOST) && ninja check_health)

.PHONY: update-health-gold
update-health-gold: download-packages download-packages-hw-host
	(cd $(BUILD)/$(HOST) && ninja clear_health_gold)
	(cd $(BUILD)/$(HOST) && ninja update_health_gold)

.PHONY: enable-external
enable-external: $(BUILD)/$(HOST)/CMakeCache.txt
	cmake -DTOIT_TEST_EXTERNAL=ON $(BUILD)/$(HOST)
	$(MAKE) download-external
	# Run rebuild-cmake so that the new files are discovered.
	$(MAKE) rebuild-cmake
	$(MAKE) download-packages

.PHONY: check-external-enabled
check-external-enabled:
	@ if ! cmake -LA -N $(BUILD)/$(HOST) | grep 'TOIT_TEST_EXTERNAL:BOOL=ON'; then \
		echo "external projects are not enabled. Run 'make enable-external' first."; \
		exit 1; \
	fi

.PHONY: disable-external
disable-external: check-external-enabled $(BUILD)/$(HOST)/CMakeCache.txt
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
	(cd $(BUILD)/$(HOST) && ninja clear_external_health_gold)
	(cd $(BUILD)/$(HOST) && ninja update_external_health_gold)

.PHONY: update-pkgs
update-pkgs:
	for d in $$(git ls-files | grep package.yaml | grep -v tests/pkg | grep -v tests/lsp/project-root-multi); do \
	  toit pkg update --project-root $$(dirname $$d); \
	done
	toit pkg update --project-root tests/pkg

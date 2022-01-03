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

BUILD_DATE = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Use 'make ESP32_ENTRY=examples/mandelbrot.toit esp32' to compile a different
# example for the ESP32 firmware.
ESP32_ENTRY=examples/hello.toit
ESP32_WIFI_SSID=
ESP32_WIFI_PASSWORD=
ESP32_PORT=
ESP32_CHIP=esp32
export IDF_TARGET=$(ESP32_CHIP)

# Use Toitware ESP-IDF fork by default.
export IDF_PATH ?= $(CURDIR)/third_party/esp-idf

ifeq ($(OS),Windows_NT)
	EXE_SUFFIX=".exe"
else
	EXE_SUFFIX=
endif

VERSION_FILE = build/host/sdk/VERSION
CROSS_ARCH=

prefix ?= /opt/toit-sdk

GO_BUILD_FLAGS ?=
ifeq ("$(GO_BUILD_FLAGS)", "")
$(eval GO_BUILD_FLAGS=CGO_ENABLED=1 GODEBUG=netdns=go)
else
$(eval GO_BUILD_FLAGS=$(GO_BUILD_FLAGS) CGO_ENABLED=1 GODEBUG=netdns=go)
endif

GO_LINK_FLAGS ?=
GO_LINK_FLAGS +=-X main.date=$(BUILD_DATE)

TOITLSP_SOURCE := $(shell find ./tools/toitlsp/ -name '*.go')
TOITPKG_VERSION := v0.0.0-20211126161923-c00da039da00

# HOST
.PHONY: all
all: tools snapshots $(VERSION_FILE)

check-env:
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
	mkdir -p build/host
	(cd build/host && cmake ../.. -G Ninja -DCMAKE_BUILD_TYPE=Release)

.PHONY: tools
tools: check-env build/host/CMakeCache.txt
	(cd build/host && ninja build_tools)

.PHONY: snapshots
snapshots: tools
	(cd build/host && ninja build_snapshots)

.PHONY: toitpkg
toitpkg: $(TOITPKG_BIN)

$(TOITPKG_BIN):
	GOBIN="$(CURDIR)"/$(dir $@) go install github.com/toitlang/tpkg/cmd/toitpkg@$(TOITPKG_VERSION)
	mv "$(CURDIR)"/$(dir $@)/toitpkg "$(CURDIR)"/$@

.PHONY: toitlsp
toitlsp: $(TOITLSP_BIN)

$(TOITLSP_BIN): $(TOITLSP_SOURCE)
	cd tools/toitlsp; $(GO_BUILD_FLAGS) go build  -ldflags "$(GO_LINK_FLAGS)" -tags 'netgo osusergo' -o "$(CURDIR)"/$@ .

.PHONY: $(VERSION_FILE)
$(VERSION_FILE):
	(cd build/host && ninja build_version_file)


# CROSS-COMPILE
.PHONY: all-cross
all-cross: tools-cross snapshots-cross

check-env-cross:
ifndef CROSS_ARCH
	$(error invalid must specify a cross-compilation targt with CROSS_ARCH.  ie: make tools-cross CROSS_ARCH=riscv64)
endif
ifeq ("$(wildcard ./toolchains/$(CROSS_ARCH).cmake)","")
	$(error invalid cross-compile target '$(CROSS_ARCH)')
endif

build/$(CROSS_ARCH)/CMakeCache.txt:
	mkdir -p build/$(CROSS_ARCH)
	(cd build/$(CROSS_ARCH) && cmake ../../ -G Ninja -DTOITC=$(CURDIR)/build/host/sdk/bin/toit.compile -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/$(CROSS_ARCH).cmake --no-warn-unused-cli)

.PHONY: tools-cross
tools-cross: build/$(CROSS_ARCH)/CMakeCache.txt tools
	(cd build/$(CROSS_ARCH) && ninja build_tools)

.PHONY: snapshots-cross
snapshots-cross: tools
	(cd build/$(CROSS_ARCH) && ninja build_snapshots)


# ESP32 VARIANTS
SNAPSHOT_DIR = build/host/sdk/snapshots
BIN_DIR = build/host/sdk/bin
TOITPKG_BIN = $(BIN_DIR)/toit.pkg$(EXE_SUFFIX)
TOITLSP_BIN = $(BIN_DIR)/toit.lsp$(EXE_SUFFIX)
TOITVM_BIN = $(BIN_DIR)/toit.run$(EXE_SUFFIX)
TOITC_BIN = $(BIN_DIR)/toit.compile$(EXE_SUFFIX)

.PHONY: esp32
esp32: check-env build/$(ESP32_CHIP)/toit.bin

build/$(ESP32_CHIP)/toit.bin build/$(ESP32_CHIP)/toit.elf: tools snapshots build/$(ESP32_CHIP)/lib/libtoit_image.a build/config.json
	make -C toolchains/$(ESP32_CHIP)/
	$(TOITVM_BIN) tools/inject_config.toit build/config.json build/$(ESP32_CHIP)/toit.bin

build/$(ESP32_CHIP)/lib/libtoit_image.a: build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s build/$(ESP32_CHIP)/CMakeCache.txt build/$(ESP32_CHIP)/include/sdkconfig.h
	(cd build/$(ESP32_CHIP) && ninja toit_image)

build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s: tools snapshots build/snapshot
	mkdir -p build/$(ESP32_CHIP)
	$(TOITVM_BIN) $(SNAPSHOT_DIR)/snapshot_to_image.snapshot build/snapshot $@

build/snapshot: $(TOITC_BIN) $(ESP32_ENTRY)
	$(TOITC_BIN) -w $@ $(ESP32_ENTRY)

build/$(ESP32_CHIP)/CMakeCache.txt:
	mkdir -p build/$(ESP32_CHIP)
	(cd build/$(ESP32_CHIP) && IMAGE=build/$(ESP32_CHIP)/$(ESP32_CHIP).image.s cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/$(ESP32_CHIP)/$(ESP32_CHIP).cmake --no-warn-unused-cli)

build/$(ESP32_CHIP)/include/sdkconfig.h:
	mkdir -p build/$(ESP32_CHIP)
	make -C toolchains/$(ESP32_CHIP) -s "$(CURDIR)"/$@

.PHONY: build/config.json
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
install-sdk: $(TOOLS) $(SNAPSHOTS)
	install -D --target-directory="$(DESTDIR)$(prefix)"/bin $(TOOLS)
	install -m 644 -D --target-directory="$(DESTDIR)$(prefix)"/bin $(TOIT_BOOT_SNAPSHOT)
	cp -R "$(CURDIR)"/lib "$(DESTDIR)$(prefix)"/lib
	find "$(DESTDIR)$(prefix)"/lib -type f -exec chmod 644 {} \;
	install -m 644 -D --target-directory="$(DESTDIR)$(prefix)"/snapshots $(SNAPSHOTS)

install: install-sdk

.PHONY: test
test:
	(cd build/host && ninja check_slow check_fuzzer_lib)

.PHONY: update-gold
update-gold:
	(cd build/host && ninja update_gold)
	(cd build/host && ninja update_minus_s_gold)

.PHONY: test-health
test-health:
	(cd build/host && ninja generate_health_sources)
	$(MAKE) build/host/CMakeCache.txt
	(cd build/host && ninja check_health)

.PHONY: update-health-gold
update-health-gold:
	(cd build/host && ninja generate_health_sources)
	$(MAKE) build/host/CMakeCache.txt
	(cd build/host && ninja update_health_gold)

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

BUILD_DATE = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Use 'make ESP32_ENTRY=examples/mandelbrot.toit' to compile a different
# example for the ESP32 firmware.
ESP32_ENTRY=examples/hello.toit
ESP32_WIFI_SSID=
ESP32_WIFI_PASSWORD=
ESP32_PORT=

.PHONY: all
all: tools

.PHONY: tools
tools: check-env toitpkg toitlsp build/host/bin/toitvm build/host/bin/toitc build/snapshots/snapshot_to_image.snapshot build/snapshots/system_message.snapshot

.PHONY: tools-riscv64
tools-riscv64: check-env toitpkg toitlsp build/riscv64/bin/toitvm build/riscv64/bin/toitc

.PHONY: build/riscv64/bin/toitvm build/riscv64/bin/toitc
build/riscv64/bin/toitvm build/riscv64/bin/toitc: build/riscv64/CMakeCache.txt
	(cd build/riscv64 && ninja build_toitvm)

build/riscv64/CMakeCache.txt: build/riscv64/
	(cd build/riscv64 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/riscv64.cmake)

.PHONY: tools-arm64
tools-arm64: check-env toitpkg toitlsp build/arm64/bin/toitvm build/arm64/bin/toitc

.PHONY: build/arm64/bin/toitvm build/arm64/bin/toitc
build/arm64/bin/toitvm build/arm64/bin/toitc: build/arm64/CMakeCache.txt
	(cd build/arm64 && ninja build_toitvm)

.PHONY: build/win64/bin/toitvm build/win64/bin/toitc
build/win64/bin/toitvm build/win64/bin/toitc: build/win64/CMakeCache.txt
	(cd build/win64 && ninja build_toitvm)

build/arm64/CMakeCache.txt: build/arm64/
	(cd build/arm64 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/arm64.cmake)

build/win64/CMakeCache.txt: build/win64/
	(cd build/win64 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/win64.cmake)

.PHONY: tools-arm32
tools-arm32: check-env toitpkg toitlsp build/arm32/bin/toitvm build/arm32/bin/toitc

.PHONY: build/arm32/bin/toitvm build/arm32/bin/toitc
build/arm32/bin/toitvm build/arm32/bin/toitc: build/arm32/CMakeCache.txt
	(cd build/arm32 && ninja build_toitvm)

build/arm32/CMakeCache.txt: build/arm32/
	(cd build/arm32 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/arm32.cmake)

.PHONY: tools-riscv64
tools-riscv64: check-env toitpkg toitlsp build/riscv64/bin/toitvm build/riscv64/bin/toitc	

.PHONY: build/riscv64/bin/toitvm build/riscv64/bin/toitc
build/riscv64/bin/toitvm build/riscv64/bin/toitc: build/riscv64/CMakeCache.txt
	(cd build/riscv64 && ninja build_toitvm)

build/riscv64/CMakeCache.txt: build/riscv64/
	(cd build/riscv64 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/riscv64.cmake)

.PHONY: tools-arm64
tools-arm64: check-env toitpkg toitlsp build/arm64/bin/toitvm build/arm64/bin/toitc

.PHONY: build/arm64/bin/toitvm build/arm64/bin/toitc
build/arm64/bin/toitvm build/arm64/bin/toitc: build/arm64/CMakeCache.txt
	(cd build/arm64 && ninja build_toitvm)

build/arm64/CMakeCache.txt: build/arm64/
	(cd build/arm64 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/arm64.cmake)

.PHONY: tools-arm32
tools-arm32: check-env toitpkg toitlsp build/arm32/bin/toitvm build/arm32/bin/toitc

.PHONY: build/arm32/bin/toitvm build/arm32/bin/toitc
build/arm32/bin/toitvm build/arm32/bin/toitc: build/arm32/CMakeCache.txt
	(cd build/arm32 && ninja build_toitvm)

build/arm32/CMakeCache.txt: build/arm32/
	(cd build/arm32 && cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/arm32.cmake)

.PHONY: esp32
esp32: check-env build/esp32/toit.bin

.PHONY: check-flash-env
check-flash-env:
ifndef ESP32_PORT
	$(error ESP32_PORT is not set)
endif

.PHONY: flash
flash: esp32 check-flash-env
	python $(IDF_PATH)/components/esptool_py/esptool/esptool.py --chip esp32 --port ${ESP32_PORT} --baud 921600 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 40m --flash_size detect 0xd000 build/esp32/ota_data_initial.bin 0x1000 build/esp32/bootloader/bootloader.bin 0x10000 build/esp32/toit.bin 0x8000 build/esp32/partitions.bin

build/esp32/toit.bin build/esp32/toit.elf: build/esp32/lib/libtoit_image.a
	make -C toolchains/esp32/

build/esp32/lib/libtoit_image.a: build/esp32/esp32.image.s build/esp32/CMakeCache.txt
	(cd build/esp32 && ninja toit_image)

.PHONY:	build/host/bin/toitvm build/host/bin/toitc
build/host/bin/toitvm build/host/bin/toitc: build/host/CMakeCache.txt
	(cd build/host && ninja build_toitvm)

build/host/CMakeCache.txt: build/host/
	(cd build/host && cmake ../.. -G Ninja -DCMAKE_BUILD_TYPE=Release)

build/esp32/CMakeCache.txt: build/esp32/
	(cd build/esp32 && IMAGE=build/esp32/esp32.image.s cmake ../../ -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../../toolchains/esp32/esp32.cmake --no-warn-unused-cli)

build/esp32/esp32.image.s: build/esp32/ build/snapshot build/host/bin/toitvm build/snapshots/snapshot_to_image.snapshot
	build/host/bin/toitvm build/snapshots/snapshot_to_image.snapshot build/snapshot $@

build/snapshots/:
	mkdir -p $@

build/snapshots/snapshot_to_image.snapshot: build/host/bin/toitc tools/snapshot_to_image.toit build/snapshots/
	build/host/bin/toitc -w $@ tools/snapshot_to_image.toit

build/snapshots/system_message.snapshot: build/host/bin/toitc tools/system_message.toit build/snapshots/
	build/host/bin/toitc -w $@ tools/system_message.toit

build/snapshot: build/host/bin/toitc $(ESP32_ENTRY)
	build/host/bin/toitc -w $@ $(ESP32_ENTRY) -Dwifi.ssid="$(ESP32_WIFI_SSID)" -Dwifi.password="$(ESP32_WIFI_PASSWORD)"

GO_USE_INSTALL = 1
GO_USE_INSTALL_FROM = 1 16
GO_VERSION = $(subst ., ,$(shell go version | cut -d" " -f 3 | cut -c 3-))
ifeq ($(shell echo "$(word 1,$(GO_VERSION)) >= $(word 1,$(GO_USE_INSTALL_FROM))" | bc), 1)
  ifeq ($(shell echo "$(word 2,$(GO_VERSION)) < $(word 2,$(GO_USE_INSTALL_FROM))" | bc), 1)
  GO_USE_INSTALL = 0
  endif
else
  GO_USE_INSTALL = 0
endif

GO_USE_INSTALL = 1
GO_USE_INSTALL_FROM = 1 16
GO_VERSION = $(subst ., ,$(shell go version | cut -d" " -f 3 | cut -c 3-))
ifeq ($(shell echo "$(word 1,$(GO_VERSION)) >= $(word 1,$(GO_USE_INSTALL_FROM))" | bc), 1)
  ifeq ($(shell echo "$(word 2,$(GO_VERSION)) < $(word 2,$(GO_USE_INSTALL_FROM))" | bc), 1)
  GO_USE_INSTALL = 0
  endif
else
  GO_USE_INSTALL = 0
endif

GO_BUILD_FLAGS ?=
ifeq ("$(GO_BUILD_FLAGS)", "")
$(eval GO_BUILD_FLAGS=CGO_ENABLED=1 GODEBUG=netdns=go)
else
$(eval GO_BUILD_FLAGS=$(GO_BUILD_FLAGS) CGO_ENABLED=1 GODEBUG=netdns=go)
endif

GO_LINK_FLAGS ?=
GO_LINK_FLAGS +=-X main.date=$(BUILD_DATE)

TOITLSP_SOURCE := $(shell find ./tools/toitlsp/ -name '*.go')
build/toitlsp: $(TOITLSP_SOURCE)
	cd tools/toitlsp; $(GO_BUILD_FLAGS) go build  -ldflags "$(GO_LINK_FLAGS)" -tags 'netgo osusergo' -o ../../build/$(notdir $@) .

.PHONY: toitlsp
toitlsp: build/toitlsp

.PHONY: toitpkg
toitpkg: build/toitpkg

TOITPKG_VERSION := "v0.0.0-20211126161923-c00da039da00"
build/toitpkg:
ifeq ($(GO_USE_INSTALL), 1)
	GOBIN=$(shell pwd)/build go install github.com/toitlang/tpkg/cmd/toitpkg@$(TOITPKG_VERSION)
else
	GO111MODULE=on GOBIN=$(shell pwd)/build go get github.com/toitlang/tpkg/cmd/toitpkg@$(TOITPKG_VERSION)
endif

build/host/:
	mkdir -p $@

build/esp32/: check-env
	mkdir -p $@
	make -C toolchains/esp32 -s $(shell pwd)/build/esp32/include/sdkconfig.h

build/riscv64/ build/arm64/ build/arm32/ build/win64/:
	mkdir -p $@

.PHONY:	clean check-env
clean:
	rm -rf build/

check-env:
ifndef IDF_PATH
	$(error IDF_PATH is not set, if you want to use the Toitware fork execute "export IDF_PATH=`pwd`/third_party/esp-idf" (see README.md))
endif

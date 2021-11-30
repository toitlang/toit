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
ESP32_WIFI_PASSWORD=
ESP32_WIFI_SSID=

.PHONY: all
all: tools

.PHONY: tools
tools: check-env toitpkg toitlsp build/host/bin/toitvm build/host/bin/toitc

.PHONY: esp32
esp32: check-env build/esp32/toit.bin

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

build/snapshot: build/ia32/bin/toitc $(ESP32_ENTRY)
	build/ia32/bin/toitc -w $@ $(ESP32_ENTRY) -Dwifi.ssid=$(ESP32_WIFI_SSID) -Dwifi.password=$(ESP32_WIFI_PASSWORD)

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
	GOBIN=$(shell pwd)/build go install github.com/toitlang/tpkg/cmd/toitpkg@$(TOITPKG_VERSION)

build/ia32/ build/host/:
	mkdir -p $@

build/esp32/: check-env
	mkdir -p $@
	make -C toolchains/esp32 -s $(shell pwd)/build/esp32/include/sdkconfig.h

.PHONY:	clean check-env
clean:
	rm -rf build/

check-env:
ifndef IDF_PATH
	$(error IDF_PATH is not set)
endif

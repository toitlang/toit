all: test

.PHONY: build/CMakeCache.txt
build/CMakeCache.txt:
	$(MAKE) rebuild-cmake

install-pkgs: rebuild-cmake
	cmake --build build --target install-pkgs

test: install-pkgs rebuild-cmake
	cmake --build build --target check

rebuild-cmake:
	mkdir -p build
	cmake -B build -DCMAKE_BUILD_TYPE=Debug

.PHONY: all test rebuild-cmake install-pkgs

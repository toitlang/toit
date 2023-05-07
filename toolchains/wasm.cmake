set(CMAKE_SYSTEM_NAME Generic)

set(TOIT_SYSTEM_NAME wasm)

set(CMAKE_ASM_NASM_COMPILER "/usr/lib/emscripten/emcc")
set(CMAKE_C_COMPILER "/usr/lib/emscripten/emcc")
set(CMAKE_CXX_COMPILER "/usr/lib/emscripten/em++")

# Skip compiler checks.
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_CXX_COMPILER_WORKS 1)

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -m32 -x assembler-with-cpp" CACHE STRING "asm flags")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -m32" CACHE STRING "c flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m32" CACHE STRING "c++ flags")

set(CMAKE_C_FLAGS_DEBUG "-O0 -g -s -rdynamic -fdiagnostics-color" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os -s" CACHE STRING "c Release flags")
set(CMAKE_C_FLAGS_ASAN "-O1 -fsanitize=address -fno-omit-frame-pointer -g" CACHE STRING "c Asan flags")
set(CMAKE_C_FLAGS_PROF "-Os -DPROF -pg" CACHE STRING "c Prof flags")

set(CMAKE_CXX_FLAGS_DEBUG "-O0 -g -s -rdynamic -fdiagnostics-color $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os -s $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Release flags")
set(CMAKE_CXX_FLAGS_ASAN "-O1 -fsanitize=address -fno-omit-frame-pointer -g" CACHE STRING "c++ Asan flags")
set(CMAKE_CXX_FLAGS_PROF "-Os -DPROF -pg" CACHE STRING "c++ Prof flags")

include_directories(third_party/esp-idf/components/mbedtls/mbedtls/include)

set(CMAKE_SYSTEM_LIBRARY_PATH /lib32 /usr/lib32)
set(FIND_LIBRARY_USE_LIB64_PATHS OFF)

enable_testing()

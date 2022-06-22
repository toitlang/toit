// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <stdint.h>
#include <cstring>
#include <new>

#ifdef DEBUG
#include <typeinfo>
#endif

// Support for profiling configuration
#if defined(PROF)
#define DEPLOY
#endif

// -----------------------------------------------------------------------------
// Build configuration:
//  DEBUG  : Debug build with plenty of debug information and verification.
//           All test code is included.
//  FAST   : Optimized build but this includes printing and validation code.
//           All test code is included.
//  DEPLOY : Optimized and minimal build for deployment.
//
//  BUILD set to either "DEBUG", "FAST", or "DEPLOY".
#if defined(DEBUG)
#if defined(FAST) || defined(DEPLOY)
#define MULTIPLE_CONFIGURATION_ERROR
#endif
#elif defined(FAST)
#if defined(DEBUG) ||defined(DEPLOY)
#define MULTIPLE_CONFIGURATION_ERROR
#endif
#elif defined(DEPLOY)
#if defined(DEBUG) || defined(FAST)
#define MULTIPLE_CONFIGURATION_ERROR
#endif
#else
#error "No build configuration specified: use only one of -DDEBUG -DFAST -DDEPLOY"
#endif

#if defined(MULTIPLE_CONFIGURATION_ERROR)
#error "More than one build configuration specified: use only one of -DDEBUG -DFAST -DDEPLOY"
#endif

// -----------------------------------------------------------------------------
// OS configuration:
//  TOIT_FREERTOS : ESP32 RTOS
//  TOIT_DARWIN   : Apple's OSX
//  TOIT_LINUX    : Ubuntu etc.

#if defined(__FREERTOS__)
#define TOIT_FREERTOS
#define TOIT_CMPCTMALLOC
#elif defined(__APPLE__)
#define TOIT_DARWIN
#define TOIT_BSD
#define TOIT_POSIX
#elif defined(WIN32)
#define TOIT_WINDOWS
#else
#define TOIT_LINUX
#define TOIT_POSIX
#endif

#if defined(TOIT_DARWIN) + defined(TOIT_LINUX) + defined(TOIT_WINDOWS) + defined(TOIT_FREERTOS) > 1
#error "More than one OS configuration specified"
#elif defined(TOIT_DARWIN) + defined(TOIT_LINUX) + defined(TOIT_WINDOWS) + defined(TOIT_FREERTOS) < 1
#error "No OS configuration specified"
#endif

#if (__WORDSIZE == 64) || __WIN64
#define BUILD_64 1
#elif (__WORDSIZE == 32) || ESP32 || __WIN32
#define BUILD_32 1
#else
#error "Expecting a 32 or 64 bit memory model"
#endif

#ifdef WIN32
#define LP64(a,b) a##ll##b
#else
#define LP64(a,b) a##l##b
#endif

// define IOT_DEVICE iff compiled for an embedded system.
#ifdef TOIT_FREERTOS
#define IOT_DEVICE
#else
// For non-embedded applications, this is where we define configuration options
// that would be determined by the model-specific sdkconfig file on an embedded
// device.
#define CONFIG_TOIT_BYTE_DISPLAY 1
#define CONFIG_TOIT_BIT_DISPLAY 1
#endif

// Define PROFILER if the bytecode profiler should be included.
#define PROFILER

typedef intptr_t word;
typedef uintptr_t uword;

#if (__WORDSIZE == 64) || __WIN64
typedef unsigned int uhalf_word;
static const int WORD_SHIFT = 3;
#else
typedef unsigned short uhalf_word;
static const int WORD_SHIFT = 2;
#endif
static_assert(sizeof(uhalf_word) == sizeof(uword) / 2, "Unexpected half-word size");

typedef signed char int8;
typedef short int16;
typedef int int32;
typedef long long int int64;

typedef unsigned char uint8;
typedef unsigned short uint16;
typedef unsigned int uint32;
typedef unsigned long long int uint64;

static const word KB_LOG2 = 10;
static const int KB = 1 << KB_LOG2;
static const word MB_LOG2 = 20;
static const int MB = 1 << MB_LOG2;
static const word GB_LOG2 = 30;
static const int GB = 1 << GB_LOG2;

static const int POINTER_SIZE = sizeof(void*);
static const int WORD_SIZE = sizeof(word);
static const int WORD_SIZE_LOG_2 = sizeof(word) == 4 ? 2 : 3;
static const int DOUBLE_SIZE = sizeof(double);
static const int HALF_WORD_SIZE = (WORD_SIZE >> 1);
static const int BYTE_SIZE = sizeof(uint8);
static const int INT32_SIZE = sizeof(int32);
static const int UINT32_SIZE = sizeof(uint32);
static const int INT64_SIZE = sizeof(int64);

static const int TOIT_PAGE_SIZE_LOG2_64 = 15;  // Page size 32kB.
static const int TOIT_PAGE_SIZE_LOG2_32 = 12;  // Page size 4kB.
#ifdef BUILD_64
static const int TOIT_PAGE_SIZE_LOG2 = TOIT_PAGE_SIZE_LOG2_64;
#else
static const int TOIT_PAGE_SIZE_LOG2 = TOIT_PAGE_SIZE_LOG2_32;
#endif
static const int TOIT_PAGE_SIZE = (1 << TOIT_PAGE_SIZE_LOG2);
static const int TOIT_PAGE_SIZE_32 = (1 << TOIT_PAGE_SIZE_LOG2_32);
static const int TOIT_PAGE_SIZE_64 = (1 << TOIT_PAGE_SIZE_LOG2_64);

static const int LARGE_INT_BIT_SIZE = INT64_SIZE * 8;
static const int WORD_BIT_SIZE = WORD_SIZE * 8;  // Number of bits in a word.
static const int BYTE_BIT_SIZE = 8;  // Number of bits in a byte.

// Because of the fixed metadata overhead we limit the max size of the
// heap for now.  Can be fixed if we can resize the metadata on demand.
// This constant is not used on embedded platforms.
#ifdef BUILD_64
static const uword MAX_HEAP = 1ull * GB;  // Metadata ca. 8.5Mbytes.
#else
static const uword MAX_HEAP = 512ull * MB;  // Metadata ca. 8.2Mbytes.
#endif

// Perhaps some ARM CPUs and platforms allow unaligned operations, but to be
// safe we disable them here.
#if !defined(__arm__)
#define ALLOW_UNALIGNED_ACCESS
#endif

static_assert(sizeof(int32) == 4, "invalid type size");
static_assert(sizeof(int64) == 8, "invalid type size");
#ifdef BUILD_64
static_assert(sizeof(word) == 8, "invalid type size");
#endif
#ifdef BUILD_32
static_assert(sizeof(word) == 4, "invalid type size");
#endif

#define NOCOPY(type) type(const type&); void operator=(const type&);
#define EXPLICIT(type) type(); NOCOPY(type)
#define USE(x) (void)(x)
#define SOMETIMES_UNUSED __attribute__ ((unused))
#define INLINE __inline__ __attribute__((__always_inline__))

// You should only use ARRAY_SIZE on statically allocated arrays.
#define ARRAY_SIZE(array)                                   \
  ((sizeof(array) / sizeof(*(array))) /                     \
  static_cast<size_t>(!(sizeof(array) % sizeof(*(array)))))

// Please use _new at allocation point to ensure proper tracking of memory usage.
// This also ensures that we call the nothrow version of new, which can handle an
// allocation failure (returns null instead of calling the constructor).
#ifdef DEBUG
#define malloc(size) toit::tracing_malloc(size, __FILE__, __LINE__)
#define realloc(ptr, size) toit::tracing_realloc(ptr, size, __FILE__, __LINE__)
#define free(p) toit::tracing_free(p, __FILE__, __LINE__)
#define _new NewMarker(__FILE__, __LINE__) * new (std::nothrow)
#else
#define _new new (std::nothrow)
#endif

// Please use null instead of nullptr or the grand old NULL.
constexpr std::nullptr_t null = nullptr;

namespace toit {

extern bool throwing_new_allowed;

#ifdef ASSERT
#undef ASSERT
#endif

#ifdef DEBUG
void* tracing_malloc(size_t size, const char* file, int line);

void* tracing_realloc(void* ptr, size_t size, const char* file, int line);

void tracing_free(void* ptr, const char* file, int line);

class NewMarker	{
 public:
  NewMarker(char const* file, int line) : file(file), line(line) { }
  char const* const file;
  int const line;
};

void trace_new(void* p, const NewMarker& record, char const* name);

template <class T> inline T* operator*(const NewMarker& mark, T* p) {
  trace_new(p, mark, typeid(T).name());
  return p;
}
#endif

// TODO: Use this scope when a thread is not expected to make any allocations,
// eg. inside a constructor that has no way to return an error.
class NoAllocationScope {
 public:
  NoAllocationScope() {}
};

// Some code (eg. std::unordered_map and std::vector) does unchecked
// allocations.  That may be OK because that code doesn't run on the device, or
// perhaps it's a bug we haven't fixed yet.  Either way, we can bracket the
// code with an instance of this RAII class for now.
class AllowThrowingNew {
 public:
  AllowThrowingNew() {
    old_throwing_new_allowed = throwing_new_allowed;
    throwing_new_allowed = true;
  }

  ~AllowThrowingNew() {
    throwing_new_allowed = old_throwing_new_allowed;
  }

  bool old_throwing_new_allowed;
};

#ifndef DEPLOY
void fail(const char* file, int line, const char* format, ...) __attribute__ ((__noreturn__));
#define ASSERT(cond) if (!(cond)) { toit::fail(__FILE__, __LINE__, "assertion failure, %s.", #cond); }
#define FATAL(message, ...) toit::fail(__FILE__, __LINE__, #message, ##__VA_ARGS__);
#ifdef TOIT_FREERTOS
#define FATAL_IF_NOT_ESP_OK(cond) do { if ((cond) != ESP_OK) toit::fail(__FILE__, __LINE__, "%s", #cond); } while (0)
#endif
#else  // DEPLOY
void fail(const char* format, ...) __attribute__ ((__noreturn__));
#define ASSERT(cond) while (false && (cond)) { }
#define FATAL(message, ...) toit::fail(#message, ##__VA_ARGS__);
#ifdef TOIT_FREERTOS
#define FATAL_IF_NOT_ESP_OK(cond) do { if ((cond) != ESP_OK) toit::fail("%s", #cond); } while (0)
#endif
#endif  // DEPLOY

#define UNIMPLEMENTED() FATAL("unimplemented")
#define UNREACHABLE() FATAL("unreachable")


// Common forward declarations.
class AlignedMemory;
class Block;
class ProgramBlock;
class ConditionVariable;
class Encoder;
class ProgramHeap;
class HeapMemory;
class ProgramHeapMemory;
class Interpreter;
class Message;
class Mutex;
class ObjectHeap;
class ObjectNotifyMessage;
class Process;
class ProcessGroup;
class Program;
class ProgramHeap;
class ProgramOrientedEncoder;
class PointerCallback;
class Scheduler;
class SchedulerThread;
class Semaphore;
class SnapshotWriter;
class SnapshotReader;
class SystemMessage;

// Forward declaration to support be-friending
// the compiler's program builder class.
namespace compiler {
  class ProgramBuilder;
}

class Object;
class Smi;
class Array;
class ByteArray;
class Instance;
class HeapObject;
class Double;
class Stack;
class Task;
class String;
class LargeInteger;

#ifdef PROFILER
class Profiler;
#endif

// If you capture too many variables, then the functor does heap allocations.
// These can fail on the device, and we can't catch that deep in the compiler's
// libraries.  By bundling the captured variables in an on-stack object we
// avoid that.
#define CAPTURE3(T1, x1, T2, x2, T3, x3)       \
  struct {                                     \
    T1 x1;                                     \
    T2 x2;                                     \
    T3 x3;                                     \
  } capture = {                                \
    .x1 = x1,                                  \
    .x2 = x2,                                  \
    .x3 = x3                                   \
  }

#define CAPTURE4(T1, x1, T2, x2, T3, x3, T4, x4)       \
  struct {                                             \
    T1 x1;                                             \
    T2 x2;                                             \
    T3 x3;                                             \
    T4 x4;                                             \
  } capture = {                                        \
    .x1 = x1,                                          \
    .x2 = x2,                                          \
    .x3 = x3,                                          \
    .x4 = x4                                           \
  }

#define CAPTURE5(T1, x1, T2, x2, T3, x3, T4, x4, T5, x5)       \
  struct {                                                     \
    T1 x1;                                                     \
    T2 x2;                                                     \
    T3 x3;                                                     \
    T4 x4;                                                     \
    T5 x5;                                                     \
  } capture = {                                                \
    .x1 = x1,                                                  \
    .x2 = x2,                                                  \
    .x3 = x3,                                                  \
    .x4 = x4,                                                  \
    .x5 = x5                                                   \
  }

#define CAPTURE6(T1, x1, T2, x2, T3, x3, T4, x4, T5, x5, T6, x6)       \
  struct {                                                             \
    T1 x1;                                                             \
    T2 x2;                                                             \
    T3 x3;                                                             \
    T4 x4;                                                             \
    T5 x5;                                                             \
    T6 x6;                                                             \
  } capture = {                                                        \
    .x1 = x1,                                                          \
    .x2 = x2,                                                          \
    .x3 = x3,                                                          \
    .x4 = x4,                                                          \
    .x5 = x5,                                                          \
    .x6 = x6                                                           \
  }

static const int BLOCK_SALT = 0x01020304;

// If we are compiling on non-embedded platforms we might still have the
// ability to iterate the malloc heap, but the malloc is switched in at
// runtime with the LD_PRELOAD trick so we don't have any headers for it.
// Keep these first four in sync with esp_heap_caps.h.
static const int ITERATE_UNLOCKED        = 1 << 0;
static const int ITERATE_ALL_ALLOCATIONS = 1 << 1;
static const int ITERATE_UNALLOCATED     = 1 << 2;
static const word ITERATE_TAG_FREE          = -1;
static const word ITERATE_TAG_HEAP_OVERHEAD = -2;

static const word ITERATE_CUSTOM_TAGS = -100;

inline void memcpy_reverse(void* dst, const void* src, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    reinterpret_cast<uint8*>(dst)[n-1-i] = reinterpret_cast<const uint8*>(src)[i];
  }
}

} // namespace toit

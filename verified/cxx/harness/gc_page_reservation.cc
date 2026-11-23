// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "os.h"
#include "process.h"
#include "program.h"
#include "uuid.h"
#include "vm.h"
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

// POSIX declarations for unrelated functions compiled in this translation unit.
extern "C" char* realpath(const char*, char*);
extern "C" int setenv(const char*, const char*, int);
extern "C" int unsetenv(const char*);

static unsigned shift, mappings, unmaps, diagnostics;
static uword length, rounded;
static void* hint;
static void* granted;
static void* release_address;
static bool reserving, invalid_release, unmap_failure;

static int modeled_page_size() { return 1 << shift; }
static void* map_pages(void* address, size_t bytes, int protection, int flags, int fd, off_t offset) {
  ++mappings;
  CXXV_ASSERT(reserving && mappings == 1 && address == hint && length > 0 && bytes == rounded && bytes >= length,
              "request the complete rounded length using the original address hint");
  CXXV_ASSERT(protection == PROT_NONE && flags == (MAP_PRIVATE | MAP_ANON) && fd == -1 && offset == 0,
              "reserve private anonymous pages without access");
  return granted;
}
static int unmap_pages(void* address, size_t bytes) {
  ++unmaps;
  CXXV_ASSERT(!invalid_release && unmaps == 1 && address == release_address && bytes == rounded && bytes > 0,
              "unmap the original base and the entire reservation exactly once");
  return unmap_failure ? -1 : 0;
}
static void report_error(const char*) { ++diagnostics; }
static void stop_process(int status) {
  CXXV_ASSERT(status == 1 && unmaps == 1 && unmap_failure && diagnostics == 1, "report and stop on unmap failure");
  abort();
}

#define getpagesize modeled_page_size
#define mmap map_pages
#define munmap unmap_pages
#define perror report_error
#define exit stop_process
#include "os_posix.cc"
#undef exit
#undef perror
#undef munmap
#undef mmap
#undef getpagesize

void toit::fail(const char*, ...) {
  CXXV_ASSERT(invalid_release && unmaps == 0, "reject an invalid release before calling munmap");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  shift = nondet_uint();
  CXXV_ASSUME(shift < 31);
  uword mask = modeled_page_size() - 1;
  length = nondet_ulong();
  bool representable = length <= (UINTPTR_MAX & ~mask);
  rounded = (length + mask) & ~mask;
  reserving = nondet_bool();
  unmap_failure = nondet_bool();
  if (reserving) {
    hint = reinterpret_cast<void*>(nondet_ulong());
    granted = reinterpret_cast<void*>(nondet_ulong());
    bool should_map = length > 0 && representable;
    void* result = toit::OS::grab_virtual_memory(hint, length);
    bool owns = should_map && granted != MAP_FAILED && granted != nullptr;
    CXXV_ASSERT(result == (owns ? granted : nullptr) && mappings == (should_map ? 1 : 0),
                "propagate the OS outcome and skip empty or unrepresentable requests");
    CXXV_ASSERT(unmaps == (should_map && granted == nullptr ? 1 : 0),
                "release an unusable zero-address mapping");
  } else {
    uword start = nondet_ulong();
    release_address = reinterpret_cast<void*>(start);
    invalid_release = length != 0 && ((start & mask) != 0 || !representable || length - 1 > UINTPTR_MAX - start);
    toit::OS::ungrab_virtual_memory(release_address, length);
    CXXV_ASSERT(!invalid_release && mappings == 0 && unmaps == (length == 0 ? 0 : 1),
                "release every valid nonempty interval and skip an empty one");
  }
  CXXV_ASSERT(diagnostics == 0 && (!unmap_failure || unmaps == 0), "unmap failures cannot return to the caller");
}

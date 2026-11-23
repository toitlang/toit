// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "os.h"
#include "process.h"
#include "program.h"
#include "uuid.h"
#include "vm.h"
#include <errno.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

// POSIX declarations omitted by the model libc, used by other functions in os_posix.cc.
extern "C" char* realpath(const char*, char*);
extern "C" int setenv(const char*, const char*, int);
extern "C" int unsetenv(const char*);

static unsigned shift, calls, diagnostics;
static bool commit, should_call, syscall_failure, invalid_release;
static int error_code;
static uword first_byte, last_byte;

static int modeled_page_size() { return 1 << shift; }

static int protect_pages(void* addr, size_t bytes, int protection) {
  ++calls;
  uword start = reinterpret_cast<uword>(addr);
  uword mask = modeled_page_size() - 1;
  CXXV_ASSERT(should_call && calls == 1 && bytes != 0 && (start & mask) == 0 && (bytes & mask) == 0,
              "protect only a nonempty aligned page interval");
  CXXV_ASSERT(bytes - 1 <= UINTPTR_MAX - start && start == first_byte &&
              start + (bytes - 1) == last_byte, "pass exactly the required first and last pages");
  CXXV_ASSERT(protection == (commit ? (PROT_READ | PROT_WRITE) : PROT_NONE), "request the correct protection");
  errno = error_code;
  return syscall_failure ? -1 : 0;
}

static void report_error(const char*) { ++diagnostics; }
static void stop_process(int code) {
  CXXV_ASSERT(code == 1 && should_call && calls == 1 && syscall_failure &&
              (!commit || error_code != ENOMEM) && diagnostics == 1, "terminate on the specified syscall errors");
  abort();
}

#define getpagesize modeled_page_size
#define mprotect protect_pages
#define perror report_error
#define exit stop_process
#include "os_posix.cc"
#undef exit
#undef perror
#undef mprotect
#undef getpagesize

void toit::fail(const char*, ...) {
  CXXV_ASSERT(invalid_release && calls == 0, "reject a wrapping release before the syscall");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  shift = nondet_uint();
  CXXV_ASSUME(shift < 31);
  commit = nondet_bool();
  syscall_failure = nondet_bool();
  error_code = nondet_int();
  uword address = nondet_ulong(), size = nondet_ulong();
  CXXV_ASSUME(address != 0);
  bool wraps = size != 0 && size - 1 > UINTPTR_MAX - address;
  bool too_large = false;
  invalid_release = !commit && wraps;
  if (size != 0 && !wraps) {
    uword end = address + (size - 1);
    uword mask = modeled_page_size() - 1;
    if (commit) {
      first_byte = address & ~mask;
      last_byte = end | mask;
      too_large = first_byte == 0 && last_byte == UINTPTR_MAX;
      should_call = !too_large;
    } else {
      // Discard partial pages at either end. Recognize the address-space
      // edges before moving one byte beyond a partial page.
      bool partial_first = (address & mask) != 0;
      bool partial_last = (end & mask) != mask;
      if ((!partial_first || (address | mask) != UINTPTR_MAX) &&
          (!partial_last || (end & ~mask) != 0)) {
        first_byte = partial_first ? (address | mask) + 1 : address;
        last_byte = partial_last ? (end & ~mask) - 1 : end;
        should_call = first_byte <= last_byte;
      }
    }
  }
  void* base = reinterpret_cast<void*>(address);
  if (commit) {
    bool ok = toit::OS::use_virtual_memory(base, size);
    CXXV_ASSERT(ok == (!wraps && !too_large && (!should_call || !syscall_failure)),
                "propagate protection success and recoverable allocation failures");
  } else {
    toit::OS::unuse_virtual_memory(base, size);
  }
  CXXV_ASSERT(!invalid_release && (!should_call || !syscall_failure || (commit && error_code == ENOMEM)),
              "fatal protection errors cannot return to the caller");
  CXXV_ASSERT(calls == (should_call ? 1 : 0) && diagnostics == 0, "empty intervals skip the syscall");
}

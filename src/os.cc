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

#include "os.h"

#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>

#include "utils.h"

#ifndef TIMEVAL_TO_TIMESPEC
#define TIMEVAL_TO_TIMESPEC(tv, ts) {                   \
  (ts)->tv_sec = (tv)->tv_sec;                          \
  (ts)->tv_nsec = (tv)->tv_usec * 1000;                 \
}
#endif
namespace toit {

Mutex* OS::_global_mutex = null;
Mutex* OS::_scheduler_mutex = null;
Mutex* OS::_resource_mutex = null;
// Unless we explicily detect an old CPU revision we assume we have a high
// (recent) CPU with no problems.
int    OS::_cpu_revision = 1000000;

void OS::timespec_increment(timespec* ts, int64 ns) {
  const int64 ns_per_second = 1000000000LL;
  ts->tv_sec += ns / ns_per_second;
  ts->tv_nsec += ns % ns_per_second;
  // Detect nanoseconds overflow (must be less than a full second).
  if (ts->tv_nsec >= ns_per_second) {
    ts->tv_nsec -= ns_per_second;
    ts->tv_sec++;
  }
  ASSERT(ts->tv_nsec >= 0);
  ASSERT(ts->tv_nsec < ns_per_second);
}

bool OS::monotonic_gettime(int64* timestamp) {
  struct timespec time = { 0, };
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return false;
  *timestamp = (time.tv_sec * 1000000LL) + (time.tv_nsec / 1000LL);
  return true;
}

static int64 monotonic_adjustment = 0;

int64 OS::get_monotonic_time() {
  int64 timestamp = 0;
  if (!monotonic_gettime(&timestamp)) return -1;
  return timestamp - monotonic_adjustment;
}

void OS::reset_monotonic_time() {
  Locker locker(OS::global_mutex());

  int64 timestamp = 0;
  if (!monotonic_gettime(&timestamp)) {
    FATAL("no monotonic clock source");
  }

  monotonic_adjustment = timestamp;
}

bool OS::get_real_time(struct timespec* time) {
  if (clock_gettime(CLOCK_REALTIME, time) == 0) return true;

  // TODO(kasper): When running inside Docker, we sometimes see the
  // clock_gettime syscall getting blocked. In that case, we try to
  // make progress by using a less precise alternative: gettimeofday.
  // One day, we should try to get rid of this workaround again.
  int gettime_errno = errno;
  struct timeval timeofday = { 0, };
  if (gettimeofday(&timeofday, NULL) != 0) {
    int gettimeofday_errno = errno;
    printf("WARNING: cannot get time: clock_gettime -> %s, gettimeofday -> %s\n",
        strerror(gettime_errno),
        strerror(gettimeofday_errno));
    return false;
  }
  TIMEVAL_TO_TIMESPEC(&timeofday, time);
  return true;
}

AlignedMemoryBase::~AlignedMemoryBase() {}

AlignedMemory::AlignedMemory(size_t size_in_bytes, size_t alignment) : size_in_bytes(size_in_bytes) {
  raw = malloc(alignment + size_in_bytes);
#ifdef TOIT_DEBUG
  memset(raw, 0xcd, alignment + size_in_bytes);
#endif
  aligned = void_cast(Utils::round_up(unvoid_cast<char*>(raw), alignment));
}

AlignedMemory::~AlignedMemory() {
  if (raw != null) {
#ifdef TOIT_DEBUG
    memset(address(), 0xde, size_in_bytes);
#endif
    free(raw);
    raw = aligned = null;
  }
}

#ifndef TOIT_FREERTOS

// The normal way to get an aligned address is to round up
// the allocation size, then discard the unaligned ends.  Here
// we try something slightly different: We try to get an allocation
// near the unaligned one.  (If that fails we'll try random
// addresses.)
static void* try_grab_aligned(void* suggestion, uword size) {
  ASSERT(size == Utils::round_up(size, TOIT_PAGE_SIZE));
  void* result = OS::grab_virtual_memory(suggestion, size);
  if (result == null) return result;
  uword numeric_address = reinterpret_cast<uword>(result);
  uword rounded = Utils::round_up(numeric_address, TOIT_PAGE_SIZE);
  if (numeric_address == rounded) return result;
  // If we got an allocation that was not toit-page-aligned,
  // then it's a pretty good guess that the next few aligned
  // addresses might work.
  OS::ungrab_virtual_memory(result, size);
  for (int i = 0; i < 4; i++) {
    void* next_suggestion = reinterpret_cast<void*>(rounded);
    result = OS::grab_virtual_memory(next_suggestion, size);
    if (result == next_suggestion) return result;
    if (result) OS::ungrab_virtual_memory(result, size);
    rounded += size;
  }
  return OS::grab_virtual_memory(reinterpret_cast<void*>(rounded), size);
}

OS::HeapMemoryRange OS::_single_range = { 0 };

void* OS::allocate_pages(uword size) {
  if (_single_range.size == 0) FATAL("GcMetadata::set_up not called");
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
  uword original_size = size;
  // First attempt, let the OS pick a location.
  void* result = try_grab_aligned(null, size);
  if (result == null) return null;
  uword numeric_address = reinterpret_cast<uword>(result);
  uword result_end = numeric_address + size;
  int attempt = 0;
  while (result < _single_range.address ||
         result_end > reinterpret_cast<uword>(_single_range.address) + _single_range.size ||
         numeric_address != Utils::round_up(numeric_address, TOIT_PAGE_SIZE)) {
    if (attempt++ > 20) FATAL("Out of memory");
    // We did not get a result in the right range.
    // Try to use a random address in the right range.
    ungrab_virtual_memory(result, size);
    uword mask = MAX_HEAP - 1;
    uword r = rand();
    r <<= TOIT_PAGE_SIZE_LOG2;  // Do this on a separate line so that it is done on a word-sized integer.
    uword suggestion = reinterpret_cast<uword>(_single_range.address) + (r & mask);
    result = try_grab_aligned(reinterpret_cast<void*>(suggestion), size);
    numeric_address = reinterpret_cast<uword>(result);
    result_end = numeric_address + size;
  }
  use_virtual_memory(result, original_size);
  return result;
}

void OS::free_pages(void* address, uword size) {
  ungrab_virtual_memory(address, size);
}

OS::HeapMemoryRange OS::get_heap_memory_range() {
  // We make a single allocation to see where in the huge address space we can
  // expect allocations.
  void* probe = grab_virtual_memory(null, TOIT_PAGE_SIZE);
  ungrab_virtual_memory(probe, TOIT_PAGE_SIZE);
  uword addr = reinterpret_cast<uword>(probe);
  uword HALF_MAX = MAX_HEAP / 2;
  if (addr < HALF_MAX) {
    // Address is near the start of address space, so we set the range
    // to be the first MAX_HEAP of the address space.
    _single_range.address = reinterpret_cast<void*>(TOIT_PAGE_SIZE);
  } else if (addr + HALF_MAX + TOIT_PAGE_SIZE < addr) {
    // Address is near the end of address space, so we set the range to
    // be the last MAX_HEAP of the address space.
    _single_range.address = reinterpret_cast<void*>(-static_cast<word>(MAX_HEAP + TOIT_PAGE_SIZE));
  } else {
    uword from = addr - MAX_HEAP / 2;
#if defined(TOIT_DARWIN) && defined(BUILD_64)
    uword to = from + MAX_HEAP;
    // On macOS, we never get addresses in the first 4Gbytes, in order to flush
    // out 32 bit uncleanness, so let's try to avoid having the range cover
    // both sides of the 4Gbytes boundary.
    const uword FOUR_GB = 4LL * GB;
    if (from < FOUR_GB && to > FOUR_GB) {
      _single_range.address = reinterpret_cast<void*>(FOUR_GB);
    } else {
#else
    {
#endif
      // We will be allocating within a symmetric range either side of this
      // single allocation.
      _single_range.address = reinterpret_cast<void*>(from);
    }
  }
  _single_range.size = MAX_HEAP;
  return _single_range;
}

#endif  // ndef TOIT_FREERTOS

} // namespace toit

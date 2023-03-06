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

Mutex* OS::global_mutex_ = null;
Mutex* OS::scheduler_mutex_ = null;
Mutex* OS::resource_mutex_ = null;
// Unless we explicily detect an old CPU revision we assume we have a high
// (recent) CPU with no problems.
int    OS::cpu_revision_ = 1000000;

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
  struct timespec time{};
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
  struct timeval timeofday{};
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
  uword increment = size;
  for (int i = 0; i < 16; i++) {
    void* next_suggestion = reinterpret_cast<void*>(rounded);
    result = OS::grab_virtual_memory(next_suggestion, size);
    if (result == next_suggestion) return result;
    if (result) OS::ungrab_virtual_memory(result, size);
    rounded += increment;
    if ((i & 3) == 3) increment *= 2;
  }
  return OS::grab_virtual_memory(reinterpret_cast<void*>(rounded), size);
}

OS::HeapMemoryRange OS::single_range_ = { 0 };

// Protected by the resource mutex.
// We keep a list of recently freed addresses, to cut down on virtual memory
// fragmentation when an application keeps growing and then shrinking its
// memory use.  This size covers about 320MB of memory fluctuation with a 32k
// page (default on 64 bit).
static const int RECENTLY_FREED_SIZE = 10000;
static int recently_freed_index = 0;
void* recently_freed[RECENTLY_FREED_SIZE];

void* OS::allocate_pages(uword size) {
  Locker locker(OS::resource_mutex());
  if (single_range_.size == 0) FATAL("GcMetadata::set_up not called");
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
  uword original_size = size;
  // First attempt, use a recently freed address.
  void* result = null;
  if (recently_freed_index != 0) {
    result = try_grab_aligned(recently_freed[--recently_freed_index], size);
  }
  if (result == null) {
    // Second attempt, let the OS pick a location.
    result = try_grab_aligned(null, size);
    if (result == null) return null;
  }
  uword numeric_address = reinterpret_cast<uword>(result);
  uword result_end = numeric_address + size;
  int attempt = 0;
  while (result < single_range_.address ||
         result_end > reinterpret_cast<uword>(single_range_.address) + single_range_.size ||
         numeric_address != Utils::round_up(numeric_address, TOIT_PAGE_SIZE)) {
    if (attempt++ > 20) FATAL("Out of memory");
    // We did not get a result in the right range.
    // Try to use a random address in the right range.
    ungrab_virtual_memory(result, size);
    uword mask = MAX_HEAP - 1;
    uword r = rand();
    r <<= TOIT_PAGE_SIZE_LOG2;  // Do this on a separate line so that it is done on a word-sized integer.
    uword suggestion = reinterpret_cast<uword>(single_range_.address) + (r & mask);
    result = try_grab_aligned(reinterpret_cast<void*>(suggestion), size);
    numeric_address = reinterpret_cast<uword>(result);
    result_end = numeric_address + size;
  }
  use_virtual_memory(result, original_size);
  return result;
}

void OS::free_pages(void* address, uword size) {
  Locker locker(OS::resource_mutex());
  if (recently_freed_index < RECENTLY_FREED_SIZE) {
    recently_freed[recently_freed_index++] = address;
  }
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
    single_range_.address = reinterpret_cast<void*>(TOIT_PAGE_SIZE);
  } else if (addr + HALF_MAX + TOIT_PAGE_SIZE < addr) {
    // Address is near the end of address space, so we set the range to
    // be the last MAX_HEAP of the address space.
    single_range_.address = reinterpret_cast<void*>(-static_cast<word>(MAX_HEAP + TOIT_PAGE_SIZE));
  } else {
    uword from = addr - MAX_HEAP / 2;
#if defined(TOIT_DARWIN) && defined(BUILD_64)
    uword to = from + MAX_HEAP;
    // On macOS, we never get addresses in the first 4Gbytes, in order to flush
    // out 32 bit uncleanness, so let's try to avoid having the range cover
    // both sides of the 4Gbytes boundary.
    const uword FOUR_GB = 4LL * GB;
    if (from < FOUR_GB && to > FOUR_GB) {
      single_range_.address = reinterpret_cast<void*>(FOUR_GB);
    } else {
#else
    {
#endif
      // We will be allocating within a symmetric range either side of this
      // single allocation.
      single_range_.address = reinterpret_cast<void*>(from);
    }
  }
  single_range_.size = MAX_HEAP;
  return single_range_;
}

#endif  // ndef TOIT_FREERTOS

} // namespace toit

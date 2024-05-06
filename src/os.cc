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

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>

#include "utils.h"

#ifndef TIMEVAL_TO_TIMESPEC
#define TIMEVAL_TO_TIMESPEC(tv, ts) {                   \
  (ts)->tv_sec = (tv)->tv_sec;                          \
  (ts)->tv_nsec = (tv)->tv_usec * 1000;                 \
}
#endif

namespace toit {

Mutex* OS::global_mutex_ = null;
Mutex* OS::tls_mutex_ = null;
Mutex* OS::process_mutex_ = null;
Mutex* OS::resource_mutex_ = null;

// Unless we explicily detect an old CPU revision we assume we have a high
// (recent) CPU with no problems.
int OS::cpu_revision_ = 1000000;

void OS::set_up_mutexes() {
  global_mutex_ = allocate_mutex(0, "Global mutex");
  // We need to be able to take the scheduler mutex (level 2), to do GC
  // while we hold the TLS mutex during handshakes.
  tls_mutex_ = allocate_mutex(1, "TLS mutex");
  process_mutex_ = allocate_mutex(4, "Process mutex");
  resource_mutex_ = allocate_mutex(99, "Resource mutex");
}

void OS::tear_down_mutexes() {
  dispose(global_mutex_);
  dispose(tls_mutex_);
  dispose(process_mutex_);
  dispose(resource_mutex_);
}

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

OS::HeapMemoryRange OS::single_range_ = { 0 };

// Protected by the resource mutex.
static void* toit_heap_range = null;  // Start of the range.
static uword toit_heap_size = 0;      // Size of the range.
static uint64* toit_heap_bits;        // Free bits for the range.

static const int BITS_PER_UINT64_LOG_2 = 6;

// Scans forwards from start of the bitmaps to find a set of free pages that
// are big enough.  On 64 bit platforms there are 512 bitmaps (each 64 bit) for
// the default max heap size of 1Gbyte.  We don't make allocations that cross
// the boundary between bitmaps. Currently the max allocation size requested is
// 256k, which is 8 pages.
static void* find_free_area(const Locker& locker, uword size) {
  int bitmaps = toit_heap_size >> (TOIT_PAGE_SIZE_LOG2 + BITS_PER_UINT64_LOG_2);
  for (int i = 0; i < bitmaps; i++) {
    uint64 map = toit_heap_bits[i];
    // Fast out for fully allocated bitmaps.
    if (map + 1 == 0) continue;  // All 1's.
    unsigned unused_pages = 64 - Utils::popcount(map);
    // Fast out - if there are not enough zero bits in the word there is no
    // point in scanning it for a long enough run.
    if (unused_pages < size) continue;
    if (size == 64) {
      uint64 zero = 0;
      toit_heap_bits[i] = zero - 1;  // All ones.
      return Utils::void_add(toit_heap_range, i << (TOIT_PAGE_SIZE_LOG2 + BITS_PER_UINT64_LOG_2));
    }
    uint64 one = 1;
    uint64 mask = (one << size) - 1;
    // Scan the bitmap word for a run of the right length.
    for (unsigned j = 0; j <= 64 - size; j++) {
      if ((map & mask) == 0) {
        toit_heap_bits[i] |= mask;
        return Utils::void_add(toit_heap_range, (i << (TOIT_PAGE_SIZE_LOG2 + BITS_PER_UINT64_LOG_2)) + (j << TOIT_PAGE_SIZE_LOG2));
      }
      mask <<= 1;
    }
  }
  return null;
}

void* OS::allocate_pages(uword size) {
  Locker locker(OS::resource_mutex());
  ASSERT(Utils::is_aligned(size, TOIT_PAGE_SIZE));
  size >>= TOIT_PAGE_SIZE_LOG2;
  ASSERT(size <= 64);  // 64 bits per bitmap, since we use uint64.
  void* result = find_free_area(locker, size);
  if (result) use_virtual_memory(result, size << TOIT_PAGE_SIZE_LOG2);
  return result;
}

void OS::free_pages(void* address, uword size) {
  Locker locker(OS::resource_mutex());
  word size_in_pages = size >> TOIT_PAGE_SIZE_LOG2;
  uword page_number = Utils::void_sub(address, toit_heap_range) >> TOIT_PAGE_SIZE_LOG2;
  uword index = page_number >> BITS_PER_UINT64_LOG_2;
  ASSERT(size_in_pages <= 64);  // 64 bits per bitmap, since we use uint64.
  uint64 old_bits = toit_heap_bits[index];
  if (size_in_pages == 64) {
    ASSERT(old_bits + 1 == 0);  // All 1's.
    toit_heap_bits[index] = 0;
  } else {
    uint64 one = 1;
    uint64 mask = (one << size_in_pages) - 1;
    uint64 new_bits = old_bits & ~(mask << (page_number & 63));
    ASSERT(Utils::popcount(old_bits) - Utils::popcount(new_bits) == size_in_pages);
    toit_heap_bits[index] = new_bits;
  }
  unuse_virtual_memory(address, size);
}

OS::HeapMemoryRange OS::get_heap_memory_range() {
  if (single_range_.address == null) {
    uword max_heap = MAX_HEAP;
    const char* max_string = getenv("TOIT_MAX_HEAP_GB");
    if (max_string) {
      long gb = 0;
      if ('0' <= max_string[0] && max_string[0] <= '9') {
        gb = strtol(max_string, null, 10);
        if (gb == LONG_MAX || gb == LONG_MIN) gb = 0;
      }
#ifdef BUILD_32
      if (gb > 1) {
        // It's not realistic to run with max heap of more than 1Gbyte on a 32 bit
        // platform.
        fprintf(stderr, "TOIT_MAX_HEAP_GB is set to %ld, but this is a 32-bit build\n", gb);
        gb = 1;
      }
#else
      if (gb > 1024) {
        // In theory, Toit can run with multi-terabyte heaps, but it's not currently
        // engineered for it, and nobody wants one hour GC pauses.
        fprintf(stderr, "TOIT_MAX_HEAP_GB is set to %ld, which is unrealistic\n", gb);
        gb = 1024;
      }
#endif
      max_heap = 1ull * GB * gb;
      if (!max_heap) {
        fprintf(stderr, "Could not parse TOIT_MAX_HEAP_GB of '%s'\n", max_string);
        max_heap = MAX_HEAP;
      }
    }

    // We grab the whole virtual memory range with an mmap, but we don't
    // actually ask for the memory. That is done on demand with mprotect.
    toit_heap_range = Utils::round_up(grab_virtual_memory(null, max_heap + TOIT_PAGE_SIZE), TOIT_PAGE_SIZE);
    if (!toit_heap_range) {
      FATAL("Could not reserve %dMbytes of address space.", static_cast<int>(max_heap >> 20));
    }
    toit_heap_size = max_heap;
    uword bitmaps = max_heap / (TOIT_PAGE_SIZE * 64);
    toit_heap_bits = reinterpret_cast<uint64*>(calloc(bitmaps, sizeof(uint64)));
    single_range_.address = toit_heap_range;
    single_range_.size = max_heap;
  }

  return single_range_;
}

#endif  // ndef TOIT_FREERTOS

} // namespace toit

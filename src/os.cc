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
#ifndef TOIT_EC618
#include <pthread.h>
#include <sys/time.h>
#include <sys/types.h>
#endif
#include <stdlib.h>
#include <time.h>

#include "utils.h"

#ifdef TOIT_EC618
extern "C" {
  #include <stdio.h>
  #include "cmsis_os2.h"
  #include "osasys.h"
  void slpManAonWdtFeed(void);
}
#endif

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
  } else if (ts->tv_nsec < 0) {
    ts->tv_nsec += ns_per_second;
    ts->tv_sec--;
  }
  ASSERT(ts->tv_nsec >= 0);
  ASSERT(ts->tv_nsec < ns_per_second);
}

#ifdef TOIT_EC618
bool OS::monotonic_gettime(int64* timestamp) {
  *timestamp = OS::get_system_time();
  return true;
}
#else
bool OS::monotonic_gettime(int64* timestamp) {
  struct timespec time{};
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return false;
  *timestamp = (time.tv_sec * 1000000LL) + (time.tv_nsec / 1000LL);
  return true;
}
#endif

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

void OS::feed_watchdog() {
#if defined(TOIT_EC618) && CONFIG_TOIT_EC618_VM_WATCHDOG
  // The vendor idle task feeds the AON watchdog through xpmuEnterTickless.
  // A healthy CPU-bound VM can keep that idle task from running. Service the
  // platform watchdog from the scheduler too; application deadlines remain
  // the responsibility of watchdog_ec618.cc. Calls are serialized by the
  // scheduler mutex. Throttle the slow-clock register access to once a second.
  static uint32_t last_feed = 0;
  uint32_t now = osKernelGetTickCount();
  if (static_cast<uint32_t>(now - last_feed) < 1000) return;
  last_feed = now;
  slpManAonWdtFeed();
#endif
}

#ifdef TOIT_EC618
bool OS::get_real_time(struct timespec* time) {
  utc_timer_value_t* utc = OsaSystemTimeReadRamUtc();
  if (utc == null || utc->UTCsecs == 0) {
    // RTC not set yet — fall back to monotonic time.
    int64 timestamp = 0;
    if (!monotonic_gettime(&timestamp)) return false;
    time->tv_sec = timestamp / 1000000LL;
    time->tv_nsec = (timestamp % 1000000LL) * 1000LL;
    return true;
  }
  time->tv_sec = utc->UTCsecs;
  time->tv_nsec = utc->UTCms * 1000000LL;
  return true;
}
#else
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
#endif

AlignedMemoryBase::~AlignedMemoryBase() {}

AlignedMemory::AlignedMemory(size_t size_in_bytes, size_t alignment)
    : size_in_bytes(size_in_bytes), raw(null), aligned(null) {
  if (alignment == 0 || !Utils::is_power_of_two(alignment)) return;
  size_t mask = alignment - 1;
  if (size_in_bytes > SIZE_MAX - mask) return;
  // Page protection rounds up the end, so the final partial page must
  // belong to this allocation too.
  size_t extent = (size_in_bytes + mask) & ~mask;
  if (extent > SIZE_MAX - alignment) return;
  size_t reserved = extent + alignment;
  raw = malloc(reserved);
  if (raw == null) return;
#ifdef TOIT_DEBUG
  memset(raw, 0xcd, reserved);
#endif
  size_t offset = -reinterpret_cast<uword>(raw) & mask;
  aligned = static_cast<uint8*>(raw) + offset;
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

#include "heap_page_scan.h"

static unsigned free_page_offset(uint64 bits, unsigned pages) {
  if (bits == UINT64_MAX || 64u - Utils::popcount(bits) < pages) return 64;
  uint64 mask = page_run_mask(pages, 0);
  for (unsigned j = 0; j <= 64 - pages; j++) {
    if ((bits & mask) == 0) return j;
    mask <<= 1;
  }
  return 64;
}

void* OS::allocate_pages(uword size) {
  Locker locker(OS::resource_mutex());
  if (size == 0 || size > 64 * TOIT_PAGE_SIZE || !Utils::is_aligned(size, TOIT_PAGE_SIZE)) return null;
  unsigned pages = static_cast<unsigned>(size >> TOIT_PAGE_SIZE_LOG2);
  uword words = toit_heap_size >> (TOIT_PAGE_SIZE_LOG2 + BITS_PER_UINT64_LOG_2);
  uword page = first_free_page(toit_heap_bits, words, pages);
  if (page == 64 * words) return null;
  void* address = Utils::void_add(toit_heap_range, page << TOIT_PAGE_SIZE_LOG2);
  if (!OS::use_virtual_memory(address, size)) return null;
  claim_page_run(toit_heap_bits, page, pages);
  return address;
}

void OS::free_pages(void* address, uword size) {
  Locker locker(OS::resource_mutex());
  ASSERT(size > 0 && size <= 64 * TOIT_PAGE_SIZE && Utils::is_aligned(size, TOIT_PAGE_SIZE));
  unsigned pages = static_cast<unsigned>(size >> TOIT_PAGE_SIZE_LOG2);
  uword page = Utils::void_sub(address, toit_heap_range) >> TOIT_PAGE_SIZE_LOG2;
  ASSERT(page % 64 <= 64 - pages);
  ASSERT((toit_heap_bits[page / 64] & page_run_mask(pages, page % 64)) == page_run_mask(pages, page % 64));
  release_page_run(toit_heap_bits, page, pages);
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
    uword reservation_size = max_heap + TOIT_PAGE_SIZE;
    void* reservation = grab_virtual_memory(null, reservation_size);
    if (!reservation) {
      FATAL("Could not reserve %dMbytes of address space.", static_cast<int>(max_heap >> 20));
    }
    uword bitmaps = max_heap / (TOIT_PAGE_SIZE * 64);
    uint64* bits = static_cast<uint64*>(calloc(bitmaps, sizeof(uint64)));
    if (!bits) {
      ungrab_virtual_memory(reservation, reservation_size);
      FATAL("Could not allocate the heap page bitmap.");
    }
    toit_heap_range = Utils::round_up(reservation, TOIT_PAGE_SIZE);
    toit_heap_size = max_heap;
    toit_heap_bits = bits;
    single_range_.address = toit_heap_range;
    single_range_.size = max_heap;
  }

  return single_range_;
}

#endif  // ndef TOIT_FREERTOS

} // namespace toit

// Copyright (C) 2026 Toit contributors.
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

#include "top.h"

#ifdef TOIT_EC618

#include "FreeRTOS.h"
#include "semphr.h"
#include "task.h"
#include <malloc.h>
#include <sys/queue.h>

extern "C" {
  #include "cmsis_os2.h"
  #include "osasys.h"
  #include "rng.h"
  // heap_stats_t, tagged_memory_callback_t, vPortGetHeapStats,
  // vPortIterateAllocations, vPortSetHeapTag, vPortGetHeapTag
  // are now declared in portable.h (included via FreeRTOS.h).

  extern uint32_t SystemCoreClock;
  extern char end_ap_data;
  extern char start_up_buffer;
}

#include "flags.h"
#include "heap_report.h"
#include "memory.h"
#include "os.h"
#include "rtc_memory_ec618.h"
#include "process.h"
#include "program.h"
#include "scheduler.h"
#include "utils.h"
#include "uuid.h"
#include "vm.h"

namespace toit {

// Task-to-thread map. We can't use FreeRTOS TLS pointers because the
// prebuilt libfreertos.a was compiled with configNUM_THREAD_LOCAL_STORAGE_POINTERS=0
// and changing it would break the TCB struct ABI.
static const int MAX_THREADS = 16;
static struct {
  TaskHandle_t task;
  Thread* thread;
} thread_map[MAX_THREADS];

int64 OS::get_system_time() {
  // Combine the current tick count with accumulated time from previous
  // sleep cycles (stored in RTC memory) to get total uptime.
  uint32_t ticks = osKernelGetTickCount();
  int64 current_ms = static_cast<int64>(ticks) * portTICK_PERIOD_MS;
  int64 wakeup_ms = RtcMemory::wakeup_time();
  return (wakeup_ms + current_ms) * 1000LL;  // ms to us.
}

int OS::num_cores() {
  return 1;  // Cortex-M3 is single-core.
}

void OS::close(int fd) {
  // Do nothing.
}

// Condition variable implementation using FreeRTOS task notifications.
// Inspired by the ESP32 implementation.
struct ConditionVariableWaiter {
  TaskHandle_t task;
  TAILQ_ENTRY(ConditionVariableWaiter) link;
};

class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex)
    : mutex_(mutex) {
    TAILQ_INIT(&waiter_list_);
  }

  ~ConditionVariable() {}

  void wait() {
    wait_ticks(portMAX_DELAY);
  }

  bool wait_us(int64 us) {
    if (us <= 0LL) return false;
    // Use ceiling division to avoid rounding ticks down.
    uint32 ms = 1 + static_cast<uint32>((us - 1) / 1000LL);
    uint32 ticks = (ms + portTICK_PERIOD_MS - 1) / portTICK_PERIOD_MS;
    return wait_ticks(ticks);
  }

  bool wait_ticks(uint32 ticks) {
    if (!mutex_->is_locked()) {
      FATAL("wait on unlocked mutex");
    }

    ConditionVariableWaiter w{};
    w.task = xTaskGetCurrentTaskHandle();

    TAILQ_INSERT_TAIL(&waiter_list_, &w, link);

    mutex_->unlock();

    uint32_t value = 0;
    bool success = xTaskNotifyWait(0x00, 0xffffffff, &value, ticks) == pdTRUE;

    mutex_->lock();
    TAILQ_REMOVE(&waiter_list_, &w, link);

    if ((value & SIGNAL_ALL) != 0) signal_all();
    return success;
  }

  void signal() {
    if (!mutex_->is_locked()) {
      FATAL("signal on unlocked mutex");
    }
    ConditionVariableWaiter* entry = TAILQ_FIRST(&waiter_list_);
    if (entry) {
      xTaskNotify(entry->task, SIGNAL_ONE, eSetBits);
    }
  }

  void signal_all() {
    if (!mutex_->is_locked()) {
      FATAL("signal_all on unlocked mutex");
    }
    ConditionVariableWaiter* entry = TAILQ_FIRST(&waiter_list_);
    if (entry) {
      xTaskNotify(entry->task, SIGNAL_ALL, eSetBits);
    }
  }

 private:
  Mutex* mutex_;
  TAILQ_HEAD(, ConditionVariableWaiter) waiter_list_;

  static const uint32 SIGNAL_ONE = 1 << 0;
  static const uint32 SIGNAL_ALL = 1 << 1;
};

const int DEFAULT_STACK_SIZE = 2 * KB;

static Thread* get_current_thread() {
  TaskHandle_t task = xTaskGetCurrentTaskHandle();
  if (task == null) return null;
  for (int i = 0; i < MAX_THREADS; i++) {
    if (thread_map[i].task == task) return thread_map[i].thread;
  }
  return null;
}

static void set_current_thread(Thread* thread) {
  TaskHandle_t task = xTaskGetCurrentTaskHandle();
  // Look for existing entry or empty slot.
  int empty = -1;
  for (int i = 0; i < MAX_THREADS; i++) {
    if (thread_map[i].task == task) {
      thread_map[i].thread = thread;
      return;
    }
    if (empty < 0 && thread_map[i].task == null) empty = i;
  }
  if (empty < 0) FATAL("too many threads");
  thread_map[empty].task = task;
  thread_map[empty].thread = thread;
}

static void clear_current_thread() {
  TaskHandle_t task = xTaskGetCurrentTaskHandle();
  for (int i = 0; i < MAX_THREADS; i++) {
    if (thread_map[i].task == task) {
      thread_map[i].task = null;
      thread_map[i].thread = null;
      return;
    }
  }
}

struct ThreadData {
  TaskHandle_t handle;
  SemaphoreHandle_t terminated;
};

Thread::Thread(const char* name)
    : name_(name)
    , handle_(null)
    , locker_(null) {}

void* thread_start(void* arg) {
  Thread* thread = unvoid_cast<Thread*>(arg);
  thread->_boot();
  return null;
}

static void ec618_thread_start(void* arg) {
  thread_start(arg);
}

void Thread::_boot() {
  auto thread = reinterpret_cast<ThreadData*>(handle_);
  set_current_thread(this);
  ASSERT(current() == this);
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + OTHER_THREADS_MALLOC_TAG);
  entry();
  clear_current_thread();
  xSemaphoreGive(thread->terminated);
  vTaskDelete(null);
}

bool Thread::spawn(int stack_size, int core) {
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + THREAD_SPAWN_MALLOC_TAG);
  ThreadData* thread = _new ThreadData();
  if (thread == null) return false;
  thread->terminated = xSemaphoreCreateBinary();
  if (thread->terminated == null) {
    delete thread;
    return false;
  }
  handle_ = void_cast(thread);

  if (stack_size == 0) stack_size = DEFAULT_STACK_SIZE;

  BaseType_t res = xTaskCreate(
    ec618_thread_start,
    name_,
    stack_size,
    this,
    tskIDLE_PRIORITY + 1,
    &thread->handle);
  if (res != pdPASS) {
    vSemaphoreDelete(thread->terminated);
    delete thread;
    return false;
  }
  return true;
}

void Thread::run() {
  ASSERT(handle_ == null);
  thread_start(void_cast(this));
}

void Thread::join() {
  ASSERT(handle_ != null);
  auto thread = reinterpret_cast<ThreadData*>(handle_);
  if (xSemaphoreTake(thread->terminated, portMAX_DELAY) != pdTRUE) {
    FATAL("Thread join failed");
  }
  vSemaphoreDelete(thread->terminated);
  delete thread;
  handle_ = null;
}

void Thread::ensure_system_thread() {
  Thread* t = get_current_thread();
  if (t != null) return;
  Thread* thread = _new SystemThread();
  if (thread == null) FATAL("unable to allocate SystemThread");
  set_current_thread(thread);
}

Thread* Thread::current() {
  Thread* result = get_current_thread();
  if (result == null) FATAL("thread must be present");
  return result;
}

void OS::set_up() {
  Thread::ensure_system_thread();
  set_up_mutexes();
  printf("[toit] INFO: running on EC618 @ %ldMHz\n", SystemCoreClock / 1000000);
}

// Mutex forwarders.
Mutex* OS::allocate_mutex(int level, const char* title) { return _new Mutex(level, title); }
void OS::dispose(Mutex* mutex) { delete mutex; }
bool OS::is_locked(Mutex* mutex) { return mutex->is_locked(); }
void OS::lock(Mutex* mutex) { mutex->lock(); }
void OS::unlock(Mutex* mutex) { mutex->unlock(); }

// Condition variable forwarders.
ConditionVariable* OS::allocate_condition_variable(Mutex* mutex) { return _new ConditionVariable(mutex); }
void OS::wait(ConditionVariable* condition) { condition->wait(); }
bool OS::wait_us(ConditionVariable* condition, int64 us) { return condition->wait_us(us); }
void OS::signal(ConditionVariable* condition) { condition->signal(); }
void OS::signal_all(ConditionVariable* condition) { condition->signal_all(); }
void OS::dispose(ConditionVariable* condition) { delete condition; }

void* OS::allocate_pages(uword size) {
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + TOIT_HEAP_MALLOC_TAG);
  void* allocation = aligned_alloc(TOIT_PAGE_SIZE, size);
  return allocation;
}

void OS::free_pages(void* address, uword size) {
  free(address);
}

void* OS::grab_virtual_memory(void* address, uword size) {
  return malloc(size);
}

void OS::ungrab_virtual_memory(void* address, uword size) {
  free(address);
}

bool OS::use_virtual_memory(void* address, uword size) {
  return true;
}

void OS::unuse_virtual_memory(void* address, uword size) {}

OS::HeapMemoryRange OS::get_heap_memory_range() {
#ifdef TOIT_CMPCTMALLOC
  heap_stats_t stats;
  vPortGetHeapStats(&stats);
  if (stats.lowest_address != null) {
    HeapMemoryRange range;
    range.address = stats.lowest_address;
    range.size = reinterpret_cast<uword>(stats.highest_address) -
                 reinterpret_cast<uword>(stats.lowest_address);
    return range;
  }
#endif
  // Fallback: use linker-defined symbols.
  HeapMemoryRange range;
  range.address = reinterpret_cast<void*>(&end_ap_data);
  range.size = reinterpret_cast<uword>(&start_up_buffer) - reinterpret_cast<uword>(&end_ap_data);
  return range;
}

void OS::tear_down() {
  // Like ESP32, skip freeing resources for fast shutdown.
}

const char* OS::get_platform() {
  return "FreeRTOS";
}

const char* OS::get_architecture() {
  return "ec618";
}

int OS::read_entire_file(char* name, uint8** buffer) {
  return -1;
}

void OS::out_of_memory(const char* reason) {
  printf("%s; restarting to attempt to recover.\n", reason);
  // TODO: Use deep sleep with RTC memory preservation once RTC memory is implemented.
  FATAL("out of memory");
}

#ifdef TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) {
  vPortSetHeapTag(reinterpret_cast<void*>(tag));
}

word OS::get_heap_tag() {
  return reinterpret_cast<word>(vPortGetHeapTag());
}

static const char* heap_tag_name(int tag) {
  switch (tag) {
    case MISC_MALLOC_TAG: return "misc";
    case EXTERNAL_BYTE_ARRAY_MALLOC_TAG: return "external byte array";
    case BIGNUM_MALLOC_TAG: return "tls/bignum";
    case EXTERNAL_STRING_MALLOC_TAG: return "external string";
    case TOIT_HEAP_MALLOC_TAG: return "toit processes";
    case FREE_MALLOC_TAG: return "free";
    case LWIP_MALLOC_TAG: return "lwip";
    case HEAP_OVERHEAD_MALLOC_TAG: return "heap overhead";
    case EVENT_SOURCE_MALLOC_TAG: return "event source";
    case OTHER_THREADS_MALLOC_TAG: return "thread/other";
    case THREAD_SPAWN_MALLOC_TAG: return "thread/spawn";
    case NULL_MALLOC_TAG: return "untagged";
    case WIFI_MALLOC_TAG: return "wifi";
    default: return "unknown";
  }
}

// Accumulates sizes by tag during heap iteration.
struct HeapReportAccumulator {
  uword sizes[NUMBER_OF_MALLOC_TAGS];
  uword counts[NUMBER_OF_MALLOC_TAGS];
};

static int accumulate_allocation(void* self, void* tag, void* address, size_t size) {
  auto acc = reinterpret_cast<HeapReportAccumulator*>(self);
  int type = compute_allocation_type(reinterpret_cast<uword>(tag));
  acc->sizes[type] += size;
  acc->counts[type]++;
  return 0;
}

void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  if (marker && strlen(marker) > 0) {
    printf("Heap report @ %s:\n", marker);
  } else {
    printf("Heap report:\n");
  }

  HeapReportAccumulator acc;
  memset(&acc, 0, sizeof(acc));
  int flags = ITERATE_ALL_ALLOCATIONS | ITERATE_UNALLOCATED;
  vPortIterateAllocations(&acc, null, reinterpret_cast<tagged_memory_callback_t>(accumulate_allocation), flags);

  word total_size = 0;
  word total_count = 0;
  for (int i = 0; i < NUMBER_OF_MALLOC_TAGS; i++) {
    if (i == FREE_MALLOC_TAG || acc.sizes[i] == 0) continue;
    printf("  %7d bytes  %5d allocs  %s\n",
        static_cast<int>(acc.sizes[i]),
        static_cast<int>(acc.counts[i]),
        heap_tag_name(i));
    total_size += acc.sizes[i];
    total_count += acc.counts[i];
  }

  heap_stats_t stats;
  vPortGetHeapStats(&stats);
  word capacity = stats.total_allocated_bytes + stats.total_free_bytes;
  printf("  Total: %d bytes in %d allocations, largest free %dk, total free %dk\n",
      static_cast<int>(total_size),
      static_cast<int>(total_count),
      static_cast<int>(stats.largest_free_block >> 10),
      static_cast<int>(stats.total_free_bytes >> 10));
}

#else  // !TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) {}
word OS::get_heap_tag() { return 0; }

void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  const uint8* uuid = process->program()->id();
  printf("%s process %d: %08x-%04x-%04x-%04x-%04x%08x.\n",
      (marker && strlen(marker) > 0) ? marker : "Out of memory",
      process->id(),
      static_cast<int>(Utils::read_unaligned_uint32_be(uuid)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 4)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 6)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 8)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 10)),
      static_cast<int>(Utils::read_unaligned_uint32_be(uuid + 12)));
}

#endif  // TOIT_CMPCTMALLOC

char* OS::getenv(const char* variable) {
  UNIMPLEMENTED();
}

bool OS::setenv(const char* variable, const char* value) {
  UNIMPLEMENTED();
}

bool OS::unsetenv(const char* variable) {
  UNIMPLEMENTED();
}

bool OS::set_real_time(struct timespec* time) {
  struct tm tm{};
  time_t secs = time->tv_sec;
  gmtime_r(&secs, &tm);
  // OsaTimerSync packing (from luat_rtc_ec618.c):
  //   Timer1: (year << 16) | (month << 8) | day
  //   Timer2: (hour << 24) | (min << 16) | (sec << 8) | timezone
  //   Timer3: milliseconds
  uint32_t t1 = (((tm.tm_year + 1900) << 16) & 0xfff0000)
              | (((tm.tm_mon + 1) << 8) & 0xff00)
              | (tm.tm_mday & 0xff);
  uint32_t t2 = ((tm.tm_hour << 24) & 0xff000000)
              | ((tm.tm_min << 16) & 0xff0000)
              | ((tm.tm_sec << 8) & 0xff00)
              | 32;  // UTC timezone (32 = no offset).
  uint32_t t3 = time->tv_nsec / 1000000;
  return OsaTimerSync(0, SET_LOCAL_TIME, t1, t2, t3) == 0;
}

// Hardware RNG for mbedTLS entropy.
extern "C" int mbedtls_hardware_poll(
    void* data, unsigned char* output, size_t len, size_t* olen) {
  size_t total = 0;
  while (total < len) {
    uint8_t rand_buf[24];
    if (rngGenRandom(rand_buf) != 0) return -1;
    size_t to_copy = Utils::min(len - total, sizeof(rand_buf));
    memcpy(output + total, rand_buf, to_copy);
    total += to_copy;
  }
  *olen = total;
  return 0;
}

}  // namespace toit

// mbedTLS platform time function (MBEDTLS_PLATFORM_MS_TIME_ALT).
extern "C" int64_t mbedtls_ms_time(void) {
  uint32_t ticks = osKernelGetTickCount();
  return static_cast<int64_t>(ticks) * portTICK_PERIOD_MS;
}

#endif  // TOIT_EC618

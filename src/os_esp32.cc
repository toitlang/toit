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

#include "top.h"

#ifdef TOIT_FREERTOS

#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_sleep.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <malloc.h>
#include <sys/time.h>
#include <sys/queue.h>

#include "os.h"
#include "flags.h"
#include "heap_report.h"
#include "memory.h"
#include "rtc_memory_esp32.h"
#include "driver/uart.h"

#include <soc/soc.h>
#include <soc/uart_reg.h>

#ifdef CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/rtc.h>
#else
  #include <esp32/rtc.h>
#endif

#include "uuid.h"

namespace toit {

void panic_put_char(char c) {
  while (((READ_PERI_REG(UART_STATUS_REG(CONFIG_ESP_CONSOLE_UART_NUM)) >> UART_TXFIFO_CNT_S)&UART_TXFIFO_CNT) >= 126) ;
  WRITE_PERI_REG(UART_FIFO_REG(CONFIG_ESP_CONSOLE_UART_NUM), c);
}

void panic_put_string(const char *str) {
  for (int i = 0; str[i]; i++) panic_put_char(str[i]);
}

void panic_put_hex(uword hex) {
  bool printing = false;
  for (int i = 28; i >= 0; i -= 4) {
    int digit = (hex >> i) & 0xf;
    if (printing || digit != 0 || i == 0) {
      panic_put_char("0123456789abcdef"[digit]);
      printing = true;
    }
  }
}

int64 OS::get_system_time() {
  // The esp_rtc_get_time_us method returns the time since RTC was cleared,
  // that is, any non-deep-sleep wakeups.
  return esp_rtc_get_time_us();
}

int OS::num_cores() {
  esp_chip_info_t info;
  esp_chip_info(&info);
  return info.cores;
}

void OS::close(int fd) {
  // Do nothing.
}

class Mutex {
 public:
  Mutex(int level, const char* name)
    : _level(level)
    , _sem(xSemaphoreCreateMutex()) {
    if (!_sem) FATAL("Failed allocating mutex semaphore")
  }

  ~Mutex() {
    vSemaphoreDelete(_sem);
  }

  void lock() {
    if (xSemaphoreTake(_sem, portMAX_DELAY) != pdTRUE) {
      FATAL("Mutex lock failed");
    }
  }

  void unlock() {
    if (xSemaphoreGive(_sem) != pdTRUE) {
      FATAL("Mutex unlock failed");
    }
  }

  bool is_locked() {
    return xSemaphoreGetMutexHolder(_sem) != null;
  }

  int level() const { return _level; }

  int _level;
  SemaphoreHandle_t _sem;
};

// Inspired by pthread_cond_t impl on esp32-idf.
struct ConditionVariableWaiter {
  // Task to wait on.
  TaskHandle_t task;
  // Link to next semaphore to be notified.
  TAILQ_ENTRY(ConditionVariableWaiter) link;
};

class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex)
    : _mutex(mutex) {
    TAILQ_INIT(&_waiter_list);
  }

  ~ConditionVariable() {
  }

  void wait() {
    wait(0);
  }

  bool wait(int timeout_in_ms) {
    if (!_mutex->is_locked()) {
      FATAL("wait on unlocked mutex");
    }
    int timeout_ticks = portMAX_DELAY;
    if (timeout_in_ms > 0) {
      timeout_ticks = timeout_in_ms / portTICK_PERIOD_MS;
    }

    ConditionVariableWaiter w = {
      .task = xTaskGetCurrentTaskHandle()
    };

    TAILQ_INSERT_TAIL(&_waiter_list, &w, link);

    _mutex->unlock();

#ifdef CONFIG_IDF_TARGET_ESP32C3
    uint32_t value = 0;
#else
    uint32 value = 0;
#endif
    bool success = xTaskNotifyWait(0x00, 0xffffffff, &value, timeout_ticks) == pdTRUE;

    _mutex->lock();
    TAILQ_REMOVE(&_waiter_list, &w, link);

    if ((value & SIGNAL_ALL) != 0) signal_all();
    return success;
  }

  void signal() {
    if (!_mutex->is_locked()) {
      FATAL("signal on unlocked mutex");
    }
    ConditionVariableWaiter* entry = TAILQ_FIRST(&_waiter_list);
    if (entry) {
      xTaskNotify(entry->task, SIGNAL_ONE, eSetBits);
    }
  }

  void signal_all() {
    if (!_mutex->is_locked()) {
      FATAL("signal_all on unlocked mutex");
    }
    ConditionVariableWaiter* entry = TAILQ_FIRST(&_waiter_list);
    if (entry) {
      xTaskNotify(entry->task, SIGNAL_ALL, eSetBits);
    }
  }

 private:
  Mutex* _mutex;

  // Head of the list of semaphores.
  TAILQ_HEAD(, ConditionVariableWaiter) _waiter_list;

  static const uint32 SIGNAL_ONE = 1 << 0;
  static const uint32 SIGNAL_ALL = 1 << 1;
};

void Locker::leave() {
  Thread* thread = Thread::current();
  if (thread->_locker != this) FATAL("unlocking would break lock order");
  thread->_locker = _previous;
  // Perform the actual unlock.
  _mutex->unlock();
}

void Locker::enter() {
  Thread* thread = Thread::current();
  int level = _mutex->level();
  Locker* previous_locker = thread->_locker;
  if (previous_locker != null) {
    int previous_level = previous_locker->_mutex->level();
    if (level <= previous_level) {
      FATAL("trying to take lock of level %d while holding lock of level %d", level, previous_level);
    }
  }
  // Lock after checking the precondition to avoid deadlocking
  // instead of just failing the precondition check.
  _mutex->lock();
  // Only update variables after we have the lock - that grants right
  // to update the locker.
  _previous = thread->_locker;
  thread->_locker = this;
}

const int DEFAULT_STACK_SIZE = 2 * KB;

// Use C++x11 thread local variables for thread pointer.
// See
//   https://docs.espressif.com/projects/esp-idf/en/latest/esp32c3/api-guides/thread-local-storage.html
//   https://gcc.gnu.org/onlinedocs/gcc-5.5.0/gcc/Thread-Local.html#Thread-Local
__thread Thread* current_thread_ = null;

struct ThreadData {
  TaskHandle_t handle;
  SemaphoreHandle_t terminated;
};

Thread::Thread(const char* name)
    : _name(name)
    , _handle(null)
    , _locker(null) {
}

void* thread_start(void* arg) {
  Thread* thread = unvoid_cast<Thread*>(arg);
  thread->_boot();
  return null;
}

void Thread::_boot() {
  auto thread = reinterpret_cast<ThreadData*>(_handle);
  current_thread_ = this;
  ASSERT(current() == this);
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + OTHER_THREADS_MALLOC_TAG);
  entry();
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
  _handle = void_cast(thread);

  if (stack_size == 0) stack_size = DEFAULT_STACK_SIZE;
  if (core == -1) core = tskNO_AFFINITY;

  BaseType_t res = xTaskCreatePinnedToCore(
    reinterpret_cast<TaskFunction_t>(thread_start),
    _name,
    stack_size,
    this,
    tskIDLE_PRIORITY + 1,  // We want to be scheduled before IDLE, but still after WiFi, etc.
    &thread->handle,
    core);
  if (res != pdPASS) {
    vSemaphoreDelete(thread->terminated);
    delete thread;
    return false;
  }
  return true;
}

// Run on current thread.
void Thread::run() {
  ASSERT(_handle == null);
  thread_start(void_cast(this));
}

void Thread::join() {
  ASSERT(_handle != null);
  auto thread = reinterpret_cast<ThreadData*>(_handle);
  if (xSemaphoreTake(thread->terminated, portMAX_DELAY) != pdTRUE) {
    FATAL("Thread join failed");
  }
  delete thread;
  _handle = null;
}

void Thread::ensure_system_thread() {
  Thread* t = current_thread_;
  if (t != null) return;
  Thread* thread = _new SystemThread();
  if (thread == null) FATAL("unable to allocate SystemThread");
  current_thread_ = thread;
}

Thread* Thread::current() {
  Thread* result = current_thread_;
  if (result == null) FATAL("thread must be present");
  return result;
}

void OS::set_up() {
  Thread::ensure_system_thread();
  _global_mutex = allocate_mutex(0, "Global mutex");
  _scheduler_mutex = allocate_mutex(4, "Scheduler mutex");
}

// Mutex forwarders.
Mutex* OS::allocate_mutex(int level, const char* title) { return _new Mutex(level, title); }
void OS::dispose(Mutex* mutex) { delete mutex; }
bool OS::is_locked(Mutex* mutex) { return mutex->is_locked(); }  // For asserts.
void OS::lock(Mutex* mutex) { mutex->lock(); }
void OS::unlock(Mutex* mutex) { mutex->unlock(); }

// Condition variable forwarders.
ConditionVariable* OS::allocate_condition_variable(Mutex* mutex) { return _new ConditionVariable(mutex); }
void OS::wait(ConditionVariable* condition_variable) { condition_variable->wait(); }
bool OS::wait(ConditionVariable* condition_variable, int timeout_in_ms) { return condition_variable->wait(timeout_in_ms); }
void OS::signal(ConditionVariable* condition_variable) { condition_variable->signal(); }
void OS::signal_all(ConditionVariable* condition_variable) { condition_variable->signal_all(); }
void OS::dispose(ConditionVariable* condition_variable) { delete condition_variable; }

void OS::free_block(Block* block) {
  heap_caps_free(reinterpret_cast<void*>(block));
}

Block* OS::allocate_block() {
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + TOIT_HEAP_MALLOC_TAG);
  void* allocation = heap_caps_aligned_alloc(TOIT_PAGE_SIZE, TOIT_PAGE_SIZE, MALLOC_CAP_8BIT | MALLOC_CAP_DEFAULT);
  if (allocation == null) return null;
  ASSERT(Utils::is_aligned(reinterpret_cast<intptr_t>(allocation), TOIT_PAGE_SIZE));
  return new (allocation) Block();
}

void OS::set_writable(Block* block, bool value) {
  // Not supported on ESP32.
}

void OS::tear_down() {
}

const char* OS::get_platform() {
  return "FreeRTOS";
}

int OS::read_entire_file(char* name, uint8** buffer) {
  return -1;
}

void OS::out_of_memory(const char* reason) {
  RtcMemory::register_out_of_memory();

  // The heap fragmentation dumper code has been temporarily disabled.
  // See https://github.com/toitware/toit/issues/3153.
  if (true) {
    panic_put_string(reason);
    panic_put_string("; restarting to attempt to recover.\n");
    esp_restart();
  }

#ifdef TOIT_CMPCTMALLOC

  panic_put_string(reason);
  panic_put_string("; dumping flash partition and restarting to attempt to recover.\n");
  // Write to core dump flash partition.

  int num_tasks = uxTaskGetNumberOfTasks();
  TaskStatus_t tasks[num_tasks];
  num_tasks = uxTaskGetSystemState(tasks, num_tasks, null);

  for (int i = 0; i < num_tasks; i++) {
    if (tasks[i].xHandle != xTaskGetCurrentTaskHandle() && strncmp(tasks[i].pcTaskName, "IDLE", 4) != 0) {
      vTaskSuspend(tasks[i].xHandle);
    }
  }

  dump_heap_fragmentation(&panic_put_char);

  for (int i = 0; i < num_tasks; i++) {
    if (tasks[i].xHandle != xTaskGetCurrentTaskHandle() && strncmp(tasks[i].pcTaskName, "IDLE", 4) != 0) {
      vTaskResume(tasks[i].xHandle);
    }
  }

#endif // def TOIT_CMPCTMALLOC

  esp_restart();
}

#ifdef TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) {
  heap_caps_set_option(MALLOC_OPTION_THREAD_TAG, reinterpret_cast<void*>(tag));
}

word OS::get_heap_tag() {
  return reinterpret_cast<word>(heap_caps_get_option(MALLOC_OPTION_THREAD_TAG));
}

class HeapSummaryPage {
  uword MASK_ = ~(TOIT_PAGE_SIZE - 1);
 public:

  HeapSummaryPage() {
    set_address(null);
  }

  bool unused() {
    return address_ == 0;
  }

  bool matches(void* a) {
    uword address = reinterpret_cast<uword>(a);
    return (address & MASK_) == address_;
  }

  void set_address(void* a) {
    address_ = (reinterpret_cast<uword>(a) & MASK_);
    memset(void_cast(sizes_), 0, sizeof sizes_);
    memset(void_cast(counts_), 0, sizeof counts_);
    users_ = 0;
    largest_free_ = 0;
  }

  static int compute_type(uword tag) {
    if (tag == 0) {
      tag = NULL_MALLOC_TAG;
    } else if (tag == 'W') {
      tag = WIFI_MALLOC_TAG;
    } else if (tag == ITERATE_TAG_FREE) {
      tag = FREE_MALLOC_TAG;
    } else if (tag == ITERATE_TAG_HEAP_OVERHEAD) {
      tag = HEAP_OVERHEAD_MALLOC_TAG;
    } else {
      tag -= ITERATE_CUSTOM_TAGS;
      if (tag < 0 || tag >= NUMBER_OF_MALLOC_TAGS) {
        tag = UNKNOWN_MALLOC_TAG;
      }
    }
    return tag;
  }

  int register_user(uword tag, uword size) {
    uint16 saturated_size = Utils::min(size, 0xffffu);
    int type = compute_type(tag);
    users_ |= 1 << type;
    sizes_[type] += saturated_size;
    counts_[type]++;
    if (type == FREE_MALLOC_TAG) {
      largest_free_ = Utils::max(largest_free_, saturated_size);
    }
    return type;
  }

  void print() {
    if (address_ == 0) return;
    printf("  ├────────────┼─────────────────────────────────────────────┤\n");
    printf("  │ %p │   Largest free = %-5d                      │\n",
        reinterpret_cast<void*>(address_), largest_free_);
    printf("  │            ├───────────┬─────────┬───────────────────────┤\n");
    printf("  │            │   Bytes   │  Count  │  Type                 │\n");
    printf("  │            ├───────────┼─────────┼───────────────────────┤\n");
    for (int i = 0; i < NUMBER_OF_MALLOC_TAGS; i++) {
      if (users_ & (1 << i)) {
        printf("  │            │ %7d   │ %6d  │  %-19s  │\n",
             sizes_[i], counts_[i], HeapSummaryPage::name_of_type(i));
      }
    }
    printf("  ├────────────┼───────────┴─────────┴───────────────────────┤\n");
  }

  static const char* name_of_type(int tag) {
    switch (tag) {
      case MISC_MALLOC_TAG: return "misc";
      case EXTERNAL_BYTE_ARRAY_MALLOC_TAG: return "external byte array";
      case BIGNUM_MALLOC_TAG: return "bignum";
      case EXTERNAL_STRING_MALLOC_TAG: return "external string";
      case TOIT_HEAP_MALLOC_TAG: return "toit";
      case UNUSED_TOIT_HEAP_MALLOC_TAG: return "unused";
      case FREE_MALLOC_TAG: return "free";
      case LWIP_MALLOC_TAG: return "lwip";
      case HEAP_OVERHEAD_MALLOC_TAG: return "heap overhead";
      case EVENT_SOURCE_MALLOC_TAG: return "event source";
      case OTHER_THREADS_MALLOC_TAG: return "other threads";
      case THREAD_SPAWN_MALLOC_TAG: return "thread spawn";
      case NULL_MALLOC_TAG: return "null tag";
      case WIFI_MALLOC_TAG: return "wifi";
    }
    return "unknown";
  }

 private:
  uword address_;
  // In order to increase the chances of being able to make a report
  // on a memory-limited ESP32 we use uint16 here, with a little risk
  // of overflow.
  uint16 users_;
  uint16 sizes_[NUMBER_OF_MALLOC_TAGS];
  uint16 counts_[NUMBER_OF_MALLOC_TAGS];
  uint16 largest_free_;
  uint16 largest_allocation_;
};

class HeapSummaryCollector {
 public:
  explicit HeapSummaryCollector(int max_pages) : max_pages_(max_pages) {
    if (max_pages > 0) {
      pages_ = _new HeapSummaryPage[max_pages];
      out_of_memory_ = (pages_ == null);
    }
    memset(void_cast(sizes_), 0, sizeof sizes_);
    memset(void_cast(counts_), 0, sizeof counts_);
  }

  word allocation_requirement() {
    return max_pages_ * sizeof(HeapSummaryPage);
  }

  bool out_of_memory() const { return out_of_memory_; }

  ~HeapSummaryCollector() {
    delete[] pages_;
  }

  void register_allocation(void* t, void* address, uword size) {
    uword tag = reinterpret_cast<uword>(t);
    if (!current_page_ || !current_page_->matches(address)) {
      current_page_ = null;
      for (int i = 0; i < max_pages_; i++) {
        if (pages_[i].matches(address)) {
          current_page_ = &pages_[i];
          break;
        }
        bool unused = pages_[i].unused();
        if (unused || i == max_pages_ - 1) {
          current_page_ = &pages_[i];
          if (!unused) dropped_pages_++;
          current_page_->set_address(address);
          break;
        }
      }
    }
    int type = current_page_
        ? current_page_->register_user(tag, size)
        : HeapSummaryPage::compute_type(tag);
    // Disregard IRAM allocations.
    if (reinterpret_cast<uword>(address) < 0x40000000) {
      sizes_[type] += size;
      counts_[type]++;
    }
  }

  void print(const char* marker) {
    if (marker && strlen(marker) > 0) {
      printf("Heap report @ %s:\n", marker);
    } else {
      printf("Heap report:\n");
    }
    printf("  ┌───────────┬─────────┬───────────────────────┐\n");
    printf("  │   Bytes   │  Count  │  Type                 │\n");
    printf("  ├───────────┼─────────┼───────────────────────┤\n");

    int size = 0;
    int count = 0;
    for (int i = 0; i < NUMBER_OF_MALLOC_TAGS; i++) {
      // Leave out free space and allocation types with no allocations.
      if (i == FREE_MALLOC_TAG || sizes_[i] == 0) continue;
      printf("  | %7d   | %6d  |  %-19s  |\n",
          sizes_[i], counts_[i], HeapSummaryPage::name_of_type(i));
      size += sizes_[i];
      // The reported overhead isn't really separate allocations, so
      // don't count them as such.
      if (i != HEAP_OVERHEAD_MALLOC_TAG) {
        count += counts_[i];
      }
    }

    multi_heap_info_t info;
    heap_caps_get_info(&info, MALLOC_CAP_8BIT);
    int capacity_bytes = info.total_allocated_bytes + info.total_free_bytes;
    int used_bytes = size * 100 / capacity_bytes;
    printf("  └───────────┴─────────┴───────────────────────┘\n");
    printf("  Total: %d bytes in %d allocations (%d%%)\n",
        size, count, used_bytes);

    int page_count = 0;
    for (int i = 0; i < max_pages_; i++) {
      if (!pages_[i].unused()) page_count++;
    }
    if (page_count == 0) return;

    printf("  ┌────────────┬─────────────────────────────────────────────┐\n");
    for (int i = 0; i < max_pages_; i++) {
      pages_[i].print();
    }
    if (dropped_pages_ > 0) {
      printf("  ├────────────┼─────────────────────────────────────────────┤\n");
      printf("  │   %8d │   Unreported pages, hit limit of %-4d       │\n",
        dropped_pages_, max_pages_);
      printf("  ├────────────┼─────────────────────────────────────────────┤\n");
    }
    printf("  └────────────┴─────────────────────────────────────────────┘\n");
  }

 private:
  HeapSummaryPage* pages_ = null;
  HeapSummaryPage* current_page_ = null;
  uword sizes_[NUMBER_OF_MALLOC_TAGS];
  uword counts_[NUMBER_OF_MALLOC_TAGS];
  const int max_pages_;
  int dropped_pages_ = 0;
  bool out_of_memory_ = false;
};

bool register_allocation(void* self, void* tag, void* address, uword size) {
  auto collector = reinterpret_cast<HeapSummaryCollector*>(self);
  collector->register_allocation(tag, address, size);
  return false;
}

void OS::heap_summary_report(int max_pages, const char* marker) {
  HeapSummaryCollector collector(max_pages);
  if (collector.out_of_memory()) {
    printf("Not enough memory for a heap report (%d bytes)\n", static_cast<int>(collector.allocation_requirement()));
    return;
  }
  int flags = ITERATE_ALL_ALLOCATIONS | ITERATE_UNALLOCATED;
  heap_caps_iterate_tagged_memory_areas(&collector, null, &register_allocation, flags);
  collector.print(marker);
}

#else // def TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) { }
word OS::get_heap_tag() { return 0; }
void OS::heap_summary_report(int max_pages, const char* marker) { }


#endif // def TOIT_CMPCTMALLOC

static const int TOIT_IMAGE_DATA_SIZE = 1024;
static const int TOIT_CONFIG_IMAGE_SIZE = TOIT_IMAGE_DATA_SIZE - UUID_SIZE;

class ImageData {
 public:
  uint32_t image_pad = 0;
  uint32_t image_magic1 = 0x7017da7a;  // "Toitdata"
  // The data between image_magic1 and image_magic2 must be a multiple of 512
  // bytes, otherwise the patching utility will not detect it. Search for
  // 0x7017da7a. Note when updating this restriction is baked into the SDK that
  // you are updating *from* so it can't be fixed without multiple SDK updates.
  uint8_t image_config[TOIT_CONFIG_IMAGE_SIZE] = {0};
  uint8_t image_uuid[UUID_SIZE] = {0};
  uint32_t image_magic2 = 0xc09f19;    // "config"
} __attribute__((packed));

// Note, you can't declare this const because then the compiler thinks it can
// just const propagate, but we are going to patch this before we flash it, so
// we don't want that.  But it's still const because it goes in a flash section.
__attribute__((section(".rodata_custom_desc"))) ImageData toit_image_data;

const uint8* OS::image_uuid() {
  return toit_image_data.image_uuid;
}

uint8* OS::image_config(size_t *length) {
  if (length) *length = TOIT_CONFIG_IMAGE_SIZE;
  // See 512-byte restriction above.
  ASSERT(((TOIT_CONFIG_IMAGE_SIZE + UUID_SIZE) & 0x1ff) == 0);
  uint8* result = (uint8*)toit_image_data.image_config;
  if (result[0] == 0) {
    // A null byte is not a valid start of a UBJSON stream.  This indicates
    // that the config data was not patched in, or was patched in at the wrong
    // address.
    FATAL("No config data in image at %x: %02x %02x", &(result[0]), result[0], result[1]);
  }
  return result;
}

const char* OS::getenv(const char* variable) {
  // Unimplemented on purpose.
  // We currently prefer not to expose environment variables on embedded devices.
  // There is no technical reason for it, so if circumstances change, one can
  // just add a call to `::getenv`.
  UNIMPLEMENTED();
}

bool OS::set_real_time(struct timespec* time) {
  if (clock_settime(CLOCK_REALTIME, time) == 0) return true;
  struct timeval timeofday = { 0, };
  TIMESPEC_TO_TIMEVAL(&timeofday, time);
  return settimeofday(&timeofday, NULL) == 0;
}

}

#endif // TOIT_FREERTOS

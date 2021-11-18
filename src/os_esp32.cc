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
#include <esp32/rtc.h>

#include "os.h"
#include "flags.h"
#include "heap_report.h"
#include "memory.h"
#include "rtc_memory_esp32.h"
#include "driver/uart.h"
#include "soc/soc.h"
#include "soc/uart_reg.h"
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

    uint32 value = 0;
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
  entry();
  xSemaphoreGive(thread->terminated);
  vTaskDelete(null);
}

bool Thread::spawn(int stack_size, int core) {
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

void OS::clear_heap_tag() {
  heap_caps_set_option(MALLOC_OPTION_THREAD_TAG, null);
}

#else // def TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) { }
void OS::clear_heap_tag() { }

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

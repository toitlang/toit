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

  extern uint32_t SystemCoreClock;
  extern char end_ap_data;
  extern char start_up_buffer;
}

#include "flags.h"
#include "heap_report.h"
#include "memory.h"
#include "os.h"
#include "process.h"
#include "program.h"
#include "scheduler.h"
#include "utils.h"
#include "uuid.h"
#include "vm.h"

namespace toit {

// Thread-local storage slot index for the Thread* pointer.
static const BaseType_t TLS_THREAD_SLOT = 0;

int64 OS::get_system_time() {
  // Use tick count converted to microseconds.
  // TODO: Account for time spent in deep sleep via RtcMemory::wakeup_time().
  uint32_t ticks = osKernelGetTickCount();
  return static_cast<int64>(ticks) * 1000LL;  // ms to us.
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
  return static_cast<Thread*>(pvTaskGetThreadLocalStoragePointer(task, TLS_THREAD_SLOT));
}

static void set_current_thread(Thread* thread) {
  vTaskSetThreadLocalStoragePointer(xTaskGetCurrentTaskHandle(), TLS_THREAD_SLOT, thread);
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
  // Use linker-defined symbols to determine the heap extent.
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
  vTaskSetThreadLocalStoragePointer(xTaskGetCurrentTaskHandle(), 1, reinterpret_cast<void*>(tag));
}

word OS::get_heap_tag() {
  return reinterpret_cast<word>(pvTaskGetThreadLocalStoragePointer(xTaskGetCurrentTaskHandle(), 1));
}

void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  // TODO: Implement full heap summary with cmpctmalloc iteration.
  if (marker && strlen(marker) > 0) {
    printf("Heap report @ %s: (not yet implemented for EC618 cmpctmalloc)\n", marker);
  }
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
  // TODO: Use OsaTimerSync() to set the EC618 RTC.
  return false;
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

#endif  // TOIT_EC618

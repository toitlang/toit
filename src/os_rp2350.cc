// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.
#include "top.h"
#ifdef TOIT_RP2350

#include <malloc.h>
#include "FreeRTOS.h"
#include "task.h"
#include "pico/stdlib.h"
#include "pico/rand.h"
#include "hardware/powman.h"
#include "hardware/watchdog.h"
#include "mbedtls/threading.h"

#include "os.h"
#include "os_freertos.h"
#include "utils.h"
#include "power_rp2350.h"

namespace toit {

static Thread* current_thread() {
  return static_cast<Thread*>(pvTaskGetThreadLocalStoragePointer(null, 0));
}

struct ThreadData {
  TaskHandle_t task;
  SemaphoreHandle_t terminated;
};

Thread::Thread(const char* name) : name_(name), handle_(null), locker_(null) {}

void* thread_start(void* arg) {
  static_cast<Thread*>(arg)->_boot();
  return null;
}

static void task_start(void* arg) {
  thread_start(arg);
  vTaskDelete(null);
}

void Thread::_boot() {
  Thread* previous = current_thread();
  vTaskSetThreadLocalStoragePointer(null, 0, this);
  entry();
  vTaskSetThreadLocalStoragePointer(null, 0, previous);
  if (handle_ != null) {
    auto data = static_cast<ThreadData*>(handle_);
    // The joiner may free data as soon as this signals. Do not use it again.
    xSemaphoreGive(data->terminated);
  }
}

bool Thread::spawn(int stack_size, int core) {
  ASSERT(core <= 0);
  auto data = _new ThreadData();
  if (data == null) return false;
  data->terminated = xSemaphoreCreateBinary();
  if (data->terminated == null) { delete data; return false; }
  if (stack_size == 0) stack_size = 8 * KB;
  handle_ = data;
  BaseType_t result = xTaskCreate(task_start, name_,
      (stack_size + sizeof(StackType_t) - 1) / sizeof(StackType_t),
      this, tskIDLE_PRIORITY + 1, &data->task);
  if (result != pdPASS) {
    handle_ = null;
    vSemaphoreDelete(data->terminated);
    delete data;
    return false;
  }
  return true;
}

void Thread::run() {
  ASSERT(handle_ == null);
  _boot();
}

void Thread::join() {
  auto data = static_cast<ThreadData*>(handle_);
  ASSERT(data != null);
  if (xSemaphoreTake(data->terminated, portMAX_DELAY) != pdTRUE) FATAL("thread join failed");
  vSemaphoreDelete(data->terminated);
  delete data;
  handle_ = null;
}

void Thread::ensure_system_thread() {
  if (current_thread() != null) return;
  auto thread = _new SystemThread();
  if (thread == null) FATAL("unable to allocate system thread");
  vTaskSetThreadLocalStoragePointer(null, 0, thread);
}

Thread* Thread::current() {
  auto thread = current_thread();
  if (thread == null) FATAL("thread must be present");
  return thread;
}

void OS::set_up() {
  Thread::ensure_system_thread();
  set_up_mutexes();
}
void OS::tear_down() { tear_down_mutexes(); }
int OS::num_cores() { return 1; }

// The SDK retains this section only across switched-core power-down and
// clears it on ordinary resets, watchdog resets, and OTA reboots.
// Use the section directly: toit_vm links SDK headers, while the executable
// owns pico_low_power and its runtime initializer.
static int64 awake_time_at_sleep __attribute__((section(".persistent_data.toit_awake_time")));
static int64 real_time_offset __attribute__((section(".persistent_data.toit_real_time")));
static int64 wakeup_time_offset = 0;

void initialize_rp2350_time() {
  if ((powman_hw->chip_reset & POWMAN_CHIP_RESET_HAD_SWCORE_PD_BITS) &&
      watchdog_hw->reason == 0) {
    wakeup_time_offset = awake_time_at_sleep + powman_timer_get_ms() * 1000 - time_us_64();
  }
}

void prepare_rp2350_time_for_sleep() {
  awake_time_at_sleep = OS::get_system_time();
}

int64 OS::get_system_time() { return wakeup_time_offset + time_us_64(); }

// No battery-backed clock yet. Keep a software offset to the hardware timer.
bool OS::get_real_time(struct timespec* time) {
  Locker locker(global_mutex());
  int64 us = get_system_time() + real_time_offset;
  time->tv_sec = us / 1000000;
  time->tv_nsec = (us % 1000000) * 1000;
  if (time->tv_nsec < 0) { time->tv_sec--; time->tv_nsec += 1000000000; }
  return true;
}
bool OS::set_real_time(struct timespec* time) {
  Locker locker(global_mutex());
  real_time_offset = static_cast<int64>(time->tv_sec) * 1000000 + time->tv_nsec / 1000 - get_system_time();
  return true;
}

Mutex* OS::allocate_mutex(int level, const char* title) { return _new Mutex(level, title); }
void OS::dispose(Mutex* mutex) { delete mutex; }
bool OS::is_locked(Mutex* mutex) { return mutex->is_locked(); }
void OS::lock(Mutex* mutex) { mutex->lock(); }
void OS::unlock(Mutex* mutex) { mutex->unlock(); }
ConditionVariable* OS::allocate_condition_variable(Mutex* mutex) { return _new ConditionVariable(mutex); }
void OS::wait(ConditionVariable* condition) { condition->wait(); }
bool OS::wait_us(ConditionVariable* condition, int64 us) { return condition->wait_us(us); }
void OS::signal(ConditionVariable* condition) { condition->signal(); }
void OS::signal_all(ConditionVariable* condition) { condition->signal_all(); }
void OS::dispose(ConditionVariable* condition) { delete condition; }

void* OS::allocate_pages(uword size) { return memalign(TOIT_PAGE_SIZE, Utils::round_up(size, TOIT_PAGE_SIZE)); }
void OS::free_pages(void* address, uword size) { free(address); }
void* OS::grab_virtual_memory(void* address, uword size) { return allocate_pages(size); }
void OS::ungrab_virtual_memory(void* address, uword size) { free(address); }
bool OS::use_virtual_memory(void* address, uword size) { return true; }
void OS::unuse_virtual_memory(void* address, uword size) {}
OS::HeapMemoryRange OS::get_heap_memory_range() {
  // Cover all on-chip SRAM, including libc's heap. PSRAM is not used yet.
  return {reinterpret_cast<void*>(0x20000000), 520 * KB};
}
void OS::set_heap_tag(word tag) {}
word OS::get_heap_tag() { return 0; }
void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  printf("RP2350 heap: %s\n", marker ? marker : "allocation failure");
}
void OS::out_of_memory(const char* reason) { panic("RP2350 out of memory: %s", reason); }
const char* OS::get_platform() { return "FreeRTOS"; }
const char* OS::get_architecture() { return "rp2350"; }
void OS::close(int fd) {}
int OS::read_entire_file(char* name, uint8** buffer) { return -1; }
char* OS::getenv(const char* name) { return null; }
bool OS::setenv(const char* name, const char* value) { return false; }
bool OS::unsetenv(const char* name) { return false; }
bool OS::get_process_cpu_times(int64* user_us, int64* system_us) { return false; }

static void mbedtls_mutex_init(mbedtls_threading_mutex_t* mutex) {
  mutex->mutex = xSemaphoreCreateMutex();
  mutex->is_valid = mutex->mutex != null;
}
static void mbedtls_mutex_free(mbedtls_threading_mutex_t* mutex) {
  if (mutex->is_valid) vSemaphoreDelete(mutex->mutex);
  mutex->is_valid = false;
}
static int mbedtls_mutex_lock(mbedtls_threading_mutex_t* mutex) {
  if (!mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
  return xSemaphoreTake(mutex->mutex, portMAX_DELAY) == pdTRUE ? 0 : MBEDTLS_ERR_THREADING_MUTEX_ERROR;
}
static int mbedtls_mutex_unlock(mbedtls_threading_mutex_t* mutex) {
  if (!mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
  return xSemaphoreGive(mutex->mutex) == pdTRUE ? 0 : MBEDTLS_ERR_THREADING_MUTEX_ERROR;
}
void set_up_mbedtls_threading() {
  mbedtls_threading_set_alt(mbedtls_mutex_init, mbedtls_mutex_free, mbedtls_mutex_lock, mbedtls_mutex_unlock);
}
extern "C" int mbedtls_hardware_poll(void*, unsigned char* output, size_t length, size_t* olen) {
  size_t done = 0;
  while (done < length) {
    uint32_t random = get_rand_32();
    size_t count = Utils::min(sizeof(random), length - done);
    memcpy(output + done, &random, count);
    done += count;
  }
  *olen = done;
  return 0;
}
}  // namespace toit

extern "C" int64_t mbedtls_ms_time(void) { return time_us_64() / 1000; }
#endif  // TOIT_RP2350

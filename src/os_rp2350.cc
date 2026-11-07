// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.
#include "top.h"
#ifdef TOIT_PICO

#include <malloc.h>
#include <unistd.h>
#include "FreeRTOS.h"
#include "task.h"
#include "pico/stdlib.h"
#include "pico/rand.h"
#ifdef TOIT_RP2350
#include "hardware/powman.h"
#endif
#include "hardware/watchdog.h"
#include "mbedtls/threading.h"
#include "mbedtls/platform_time.h"

#include "os.h"
#include "os_freertos.h"
#include "process.h"
#include "utils.h"
#include "power_rp2350.h"
#ifdef TOIT_RP2040
#include "heap_rp2040.h"
#endif

extern "C" char __StackLimit;

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

void Thread::cancel() {
  // Like ESP32, use cooperative cancellation. The async worker observes its
  // stopped state after returning from the current operation.
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
#ifdef TOIT_RP2350
static int64 awake_time_at_sleep __attribute__((section(".persistent_data.toit_awake_time")));
static int64 real_time_offset __attribute__((section(".persistent_data.toit_real_time")));
#else
static int64 real_time_offset = 0;
#endif
static int64 wakeup_time_offset = 0;

void initialize_rp2350_time() {
#ifdef TOIT_RP2350
  if ((powman_hw->chip_reset & POWMAN_CHIP_RESET_HAD_SWCORE_PD_BITS) &&
      watchdog_hw->reason == 0) {
    wakeup_time_offset = awake_time_at_sleep + powman_timer_get_ms() * 1000 - time_us_64();
  }
#endif
}

void prepare_rp2350_time_for_sleep() {
#ifdef TOIT_RP2350
  awake_time_at_sleep = OS::get_system_time();
#endif
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
  return {reinterpret_cast<void*>(SRAM_BASE), SRAM_END - SRAM_BASE};
}
void OS::set_heap_tag(word tag) {
#ifdef TOIT_RP2040
  cmpct_platform_set_tag(reinterpret_cast<void*>(tag));
#endif
}
word OS::get_heap_tag() {
#ifdef TOIT_RP2040
  return reinterpret_cast<word>(cmpct_platform_get_tag());
#else
  return 0;
#endif
}
void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  printf("%s heap: %s\n", get_architecture(), marker ? marker : "allocation failure");
#ifdef TOIT_RP2040
  multi_heap_info_t info;
  toit_rp2040_heap_info(&info);
  printf("  heap: allocated=%u free=%u largest=%u free-blocks=%u\n",
      static_cast<unsigned>(info.total_allocated_bytes), static_cast<unsigned>(info.total_free_bytes),
      static_cast<unsigned>(info.largest_free_block), static_cast<unsigned>(info.free_blocks));
#else
  // Capture without allocating: this report must also work after allocation
  // failure. Free arena bytes need not form a contiguous (or aligned) block.
  vTaskSuspendAll();
  struct mallinfo info = mallinfo();
  void* heap_end = sbrk(0);
  xTaskResumeAll();
  printf("  libc: allocated=%d free=%d free-blocks=%d uncommitted=%u\n",
      info.uordblks, info.fordblks, info.ordblks,
      heap_end == reinterpret_cast<void*>(-1) ? 0 :
          static_cast<unsigned>(reinterpret_cast<uword>(&__StackLimit) - reinterpret_cast<uword>(heap_end)));
#endif
  if (process != null) {
    auto heap = process->object_heap();
    printf("  process %d: allocated=%lld reserved=%lld external=%u\n",
        process->id(), static_cast<long long>(heap->bytes_allocated()),
        static_cast<long long>(heap->bytes_reserved()), static_cast<unsigned>(heap->external_memory()));
  }
}
void OS::out_of_memory(const char* reason) { panic("%s out of memory: %s", get_architecture(), reason); }
const char* OS::get_platform() { return "FreeRTOS"; }
const char* OS::get_architecture() {
#ifdef TOIT_RP2040
  return "rp2040";
#else
  return "rp2350";
#endif
}
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
static mbedtls_time_t tls_wall_time(mbedtls_time_t* result) {
  struct timespec now;
  if (!OS::get_real_time(&now)) return -1;
  mbedtls_time_t seconds = now.tv_sec;
  if (result) *result = seconds;
  return seconds;
}

void set_up_mbedtls_threading() {
  mbedtls_threading_set_alt(mbedtls_mutex_init, mbedtls_mutex_free, mbedtls_mutex_lock, mbedtls_mutex_unlock);
  mbedtls_platform_set_time(tls_wall_time);
}
extern "C" int mbedtls_hardware_poll(void*, unsigned char* output, size_t length, size_t* olen) {
  // Input to mbedTLS conditioning, not direct cryptographic output. On
  // RP2040 pico_rand mixes ROSC samples and system state; RP2350 adds TRNG.
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
#endif  // TOIT_PICO

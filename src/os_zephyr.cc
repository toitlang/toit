// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.
#include "top.h"
#ifdef TOIT_ZEPHYR

#include <malloc.h>
#include <unistd.h>
#include <sys/time.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/entropy.h>
#include "mbedtls/threading.h"
#include "mbedtls/entropy.h"
#include "mbedtls/platform_time.h"

#include "os.h"
#include "os_zephyr.h"
#include "process.h"
#include "utils.h"


namespace toit {

static Thread* current_thread() {
  return static_cast<Thread*>(k_thread_custom_data_get());
}
struct ThreadData {
  struct k_thread thread;
  k_thread_stack_t* stack;
};
Thread::Thread(const char* name) : name_(name), handle_(null), locker_(null) {}
void* thread_start(void* arg) { static_cast<Thread*>(arg)->_boot(); return null; }
static void task_start(void* arg, void*, void*) { thread_start(arg); }
void Thread::_boot() {
  Thread* previous = current_thread();
  k_thread_custom_data_set(this);
  entry();
  k_thread_custom_data_set(previous);
}
bool Thread::spawn(int stack_size, int core) {
  ASSERT(core <= 0);
  if (stack_size == 0) stack_size = 8 * KB;
  auto data = _new ThreadData();
  if (data == null) return false;
  data->stack = k_thread_stack_alloc(stack_size, 0);
  if (data->stack == null) { delete data; return false; }
  handle_ = data;
  k_tid_t id = k_thread_create(&data->thread, data->stack, stack_size,
      task_start, this, null, null, 5, K_FP_REGS, K_NO_WAIT);
  k_thread_name_set(id, name_);
  return true;
}
void Thread::run() { ASSERT(handle_ == null); _boot(); }
void Thread::join() {
  auto data = static_cast<ThreadData*>(handle_);
  ASSERT(data != null);
  if (k_thread_join(&data->thread, K_FOREVER) != 0) FATAL("thread join failed");
  k_thread_stack_free(data->stack);
  delete data;
  handle_ = null;
}
void Thread::cancel() { /* Event workers use cooperative cancellation. */ }
void Thread::ensure_system_thread() {
  if (current_thread() != null) return;
  auto thread = _new SystemThread();
  if (thread == null) FATAL("unable to allocate system thread");
  k_thread_custom_data_set(thread);
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

static int64 real_time_offset = 0;
int64 OS::get_system_time() { return k_ticks_to_us_floor64(k_uptime_ticks()); }

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
  return {reinterpret_cast<void*>(DT_REG_ADDR(DT_CHOSEN(zephyr_sram))),
          DT_REG_SIZE(DT_CHOSEN(zephyr_sram))};
}
void OS::set_heap_tag(word tag) {}
word OS::get_heap_tag() { return 0; }
void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  printf("%s heap: %s\n", get_architecture(), marker ? marker : "allocation failure");

  k_sched_lock();
  struct mallinfo info = mallinfo();
  k_sched_unlock();
  printf("  libc: allocated=%d free=%d free-blocks=%d\n", info.uordblks, info.fordblks, info.ordblks);
  if (process != null) {
    auto heap = process->object_heap();
    printf("  process %d: allocated=%lld reserved=%lld external=%u\n",
        process->id(), static_cast<long long>(heap->bytes_allocated()),
        static_cast<long long>(heap->bytes_reserved()), static_cast<unsigned>(heap->external_memory()));
  }
}
void OS::out_of_memory(const char* reason) { FATAL("Zephyr out of memory: %s", reason); }
const char* OS::get_platform() { return "Zephyr"; }
const char* OS::get_architecture() { return CONFIG_SOC; }
void OS::close(int fd) {}
int OS::read_entire_file(char* name, uint8** buffer) { return -1; }
char* OS::getenv(const char* name) { return null; }
bool OS::setenv(const char* name, const char* value) { return false; }
bool OS::unsetenv(const char* name) { return false; }
bool OS::get_process_cpu_times(int64* user_us, int64* system_us) { return false; }

static void mbedtls_mutex_init(mbedtls_threading_mutex_t* mutex) {
  k_mutex_init(&mutex->mutex);
  mutex->is_valid = true;
}
static void mbedtls_mutex_free(mbedtls_threading_mutex_t* mutex) {
  mutex->is_valid = false;
}
static int mbedtls_mutex_lock(mbedtls_threading_mutex_t* mutex) {
  if (!mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
  return k_mutex_lock(&mutex->mutex, K_FOREVER) == 0 ? 0 : MBEDTLS_ERR_THREADING_MUTEX_ERROR;
}
static int mbedtls_mutex_unlock(mbedtls_threading_mutex_t* mutex) {
  if (!mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
  return k_mutex_unlock(&mutex->mutex) == 0 ? 0 : MBEDTLS_ERR_THREADING_MUTEX_ERROR;
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
  const device* source = DEVICE_DT_GET(DT_CHOSEN(zephyr_entropy));
  *olen = 0;
  if (!device_is_ready(source)) return MBEDTLS_ERR_ENTROPY_SOURCE_FAILED;
  while (*olen < length) {
    size_t count = Utils::min(length - *olen, static_cast<size_t>(UINT16_MAX));
    if (entropy_get_entropy(source, output + *olen, count) != 0) return MBEDTLS_ERR_ENTROPY_SOURCE_FAILED;
    *olen += count;
  }
  return 0;
}
}  // namespace toit

extern "C" int64_t mbedtls_ms_time(void) { return toit::OS::get_system_time() / 1000; }
#endif  // TOIT_ZEPHYR

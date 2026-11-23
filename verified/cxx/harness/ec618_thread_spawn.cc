// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#define private public
#include "os.h"
#undef private
#include "heap_report.h"
#include "utils.h"

namespace toit {
using StackType_t = uint32_t;
using BaseType_t = int;
using TaskHandle_t = void*;
using SemaphoreHandle_t = void*;
constexpr int pdPASS = 1;
constexpr int tskIDLE_PRIORITY = 0;

static int semaphore, task, parent_task;
static TaskHandle_t running = &parent_task;
static word parent_tag, child_tag;
static Thread* parent_thread;
static unsigned tag_changes;
static Thread* expected_thread;
static const char* expected_name;
static unsigned expected_words;
static bool created, called, acquired, live;

word OS::get_heap_tag() { return running == &parent_task ? parent_tag : child_tag; }
void OS::set_heap_tag(word value) {
  if (running == &parent_task) { parent_tag = value; ++tag_changes; }
  else child_tag = value;
}

static uint32_t mask;
static uint32_t __get_PRIMASK() { return mask; }
static void __disable_irq() { mask = 1; }
static void __DMB() { CXXV_ASSERT(mask == 1, "map barrier inside critical section"); }
static void __set_PRIMASK(uint32_t value) { mask = value; }
static TaskHandle_t xTaskGetCurrentTaskHandle() { return running; }
// The modeled lifecycle always has room in the map and a live task. Any
// production fatal path, including a failed join, is a proof failure here.
#undef FATAL
#define FATAL(...) CXXV_ASSERT(false, "valid lifecycle never enters a fatal path")
#include "thread_map.inc"

static unsigned entries, signals, takes, deletions;
static bool signaled, waiting, join_at_signal;
static word worker_tag;
static constexpr unsigned portMAX_DELAY = UINT32_MAX;
static constexpr int pdTRUE = 1;

static void ec618_thread_start(void*);
static void dispatch_worker() {
  CXXV_ASSERT(running == &parent_task && mask == 0 && entries == 0, "dispatch once from parent task");
  running = &task;
  ec618_thread_start(expected_thread);
  CXXV_ASSERT(get_current_thread() == nullptr && mask == 0, "worker unregisters before task handle reuse");
  running = &parent_task;
  CXXV_ASSERT(get_current_thread() == parent_thread, "worker leaves parent's registration intact");
}
static int xSemaphoreTake(SemaphoreHandle_t handle, unsigned delay) {
  CXXV_ASSERT(running == &parent_task && get_current_thread() == parent_thread && live && handle == &semaphore && delay == portMAX_DELAY && !waiting,
              "join waits on the live termination semaphore");
  ++takes;
  waiting = true;
  if (!signaled) dispatch_worker();
  CXXV_ASSERT(signaled, "the join wait returns only after the worker signals");
  signaled = false;
  waiting = false;
  return pdTRUE;
}
static void xSemaphoreGive(SemaphoreHandle_t handle) {
  CXXV_ASSERT(live && handle == &semaphore && entries == 1 && !signaled &&
              get_current_thread() == nullptr && OS::get_heap_tag() == worker_tag,
              "worker restores its tag and unregisters before signaling completion");
  ++signals;
  signaled = true;
  if (join_at_signal && !waiting) {
    running = &parent_task;
    expected_thread->join();
    running = &task;
  }
}
static void vTaskDelete(TaskHandle_t handle) {
  CXXV_ASSERT(handle == nullptr && signals == 1 && OS::get_heap_tag() == worker_tag,
              "worker self-deletes after completion and tag cleanup");
  ++deletions;
}

static SemaphoreHandle_t xSemaphoreCreateBinary() {
  acquired = live = nondet_bool();
  return live ? &semaphore : nullptr;
}

static void vSemaphoreDelete(SemaphoreHandle_t handle) {
  CXXV_ASSERT(live && handle == &semaphore, "delete the acquired semaphore exactly once");
  live = false;
}

static BaseType_t xTaskCreate(void (*)(void*), const char*, uint16_t, void*, unsigned, TaskHandle_t*);
#include "thread_spawn.inc"

class SpawnThread : public Thread {
 public:
  explicit SpawnThread(const char* name) : Thread(name) {}
  void entry() override {
    CXXV_ASSERT(Thread::current() == this && OS::get_heap_tag() == ITERATE_CUSTOM_TAGS + OTHER_THREADS_MALLOC_TAG,
                "entry runs as the registered worker with its allocation tag");
    if (running == &task && nondet_bool()) {
      CXXV_ASSERT(mask == 0, "task switch outside the map guard");
      running = &parent_task;
      CXXV_ASSERT(get_current_thread() == parent_thread, "parent lookup while worker remains registered");
      running = &task;
      CXXV_ASSERT(Thread::current() == this, "worker lookup after the parent used the cache");
    }
    ++entries;
  }
};

static BaseType_t xTaskCreate(void (*entry)(void*), const char* name, uint16_t depth,
                              void* owner, unsigned priority, TaskHandle_t* output) {
  CXXV_ASSERT(expected_words >= 18 && expected_words <= UINT16_MAX && depth == expected_words,
              "pass the exact representable frame-safe word count");
  CXXV_ASSERT(entry == ec618_thread_start && owner == expected_thread && name == expected_name &&
              live && priority == 1 && expected_thread->handle_ != nullptr,
              "publish the thread data before the task may start");
  auto data = static_cast<ThreadData*>(expected_thread->handle_);
  CXXV_ASSERT(data->terminated == &semaphore && output == &data->handle,
              "new task can access its termination semaphore and handle slot");
  called = true;
  created = nondet_bool();
  if (created) {
    *output = &task;
    // The RTOS may run the new task while its creator is still inside spawn.
    if (nondet_bool()) dispatch_worker();
  }
  return created ? pdPASS : -1;
}

}  // namespace toit

int main() {
  using namespace toit;
  expected_name = "spawn";
  SpawnThread thread(expected_name);
  expected_thread = &thread;
  SystemThread caller;
  parent_thread = nondet_bool() ? &caller : nullptr;
  if (parent_thread) set_current_thread(parent_thread);
  if (nondet_bool()) {
    word original_tag = parent_tag = nondet_word();
    thread.run();
    CXXV_ASSERT(get_current_thread() == parent_thread && parent_tag == original_tag && entries == 1 &&
                signals == 0 && deletions == 0, "synchronous run restores the calling task");
    return 0;
  }
  int bytes = nondet_int();
  int64_t effective = bytes == 0 ? 2048 : bytes;
  expected_words = effective < 0 ? 0 : static_cast<unsigned>((effective + 3) / 4);
  bool valid = expected_words >= 18 && expected_words <= UINT16_MAX;
  word old_tag = parent_tag = nondet_word();
  worker_tag = child_tag = nondet_word();
  bool ok = thread.spawn(bytes);
  CXXV_ASSERT(ok == created && called == acquired && (!called || valid), "task creation determines spawn success");
  CXXV_ASSERT(parent_tag == old_tag && tag_changes == (valid ? 2u : 0u),
              "reject invalid requests before resource acquisition and restore allocation tag");
  CXXV_ASSERT(live == ok, "retain a semaphore only after successful creation");
  auto data = static_cast<ThreadData*>(thread.handle_);
  if (ok) {
    CXXV_ASSERT(data && data->handle == &task && data->terminated == &semaphore,
                "join sees the live task and termination semaphore");
    join_at_signal = nondet_bool();
    if (!entries && nondet_bool()) dispatch_worker();
    if (takes == 0) thread.join();
    CXXV_ASSERT(entries == 1 && signals == 1 && takes == 1 && deletions == 1 &&
                thread.handle_ == nullptr && !live && !signaled,
                "spawned worker completes once and join reclaims both resources");
  } else {
    CXXV_ASSERT(data == nullptr, "failed spawn leaves the thread detached");
  }
}

// Copyright (C) 2026 Toit contributors.
#include "prelude.h"
#include <atomic>

// Execute the source constructors and the EC618 stop/entry protocol with
// modeled allocation, worker scheduling and one blocking FIFO sender.
namespace toit {
static bool allocated, spawned, started, pending_stop, stopped, joined, deleted;
static unsigned queued, delivered;
static unsigned critical;
static bool in_isr, task_producer, closing;
static int storage;
static bool unpublished();
static constexpr unsigned portMAX_DELAY = UINT32_MAX;
static constexpr int pdTRUE = 1;
struct Event {
  enum Type { DATA, STOP } type;
  word data;
};
struct EventSource {
  EventSource(const char*, int = 0) {}
  int* mutex() { return &storage; }
};
struct Thread {
  explicit Thread(const char*) {}
  bool spawn(int = 0) {
    CXXV_ASSERT(allocated && !started && unpublished(), "spawn requires its resource and precedes publication");
    return started = spawned;
  }
  void join();
};
struct OS {
  static int* allocate_condition_variable(int*) { return allocated ? &storage : nullptr; }
};
struct Locker { explicit Locker(int*) {} };
struct Ec618EventMailbox {
  bool publish(Event::Type, word) {
    CXXV_ASSERT(!closing && !deleted && (in_isr || critical != 0),
                "producer holds the live mailbox through publication");
    return nondet_bool();
  }
  static bool retains(Event::Type) { return false; }
  template<class F> void drain(F) {}
};
struct TimerEventSource : EventSource, Thread {
  static TimerEventSource* instance_;
  int* timer_changed_;
  bool stop_;
  TimerEventSource();
};
struct Ec618EventSource;
struct ObservedInstance : std::atomic<Ec618EventSource*> {
  ObservedInstance() : std::atomic<Ec618EventSource*>(nullptr) {}
  Ec618EventSource* load(std::memory_order order) const {
    CXXV_ASSERT(!task_producer || critical != 0, "pin task before loading the shared source");
    return std::atomic<Ec618EventSource*>::load(order);
  }
};
struct Ec618EventSource : EventSource, Thread {
  static ObservedInstance instance_;
#include "event_worker_instance.inc"
  int* queue_;
  Ec618EventMailbox mailbox_;
  Ec618EventSource();
  ~Ec618EventSource();
  void entry();
  static void send_event(Event::Type, word);
  static void send_event_from_isr(Event::Type, word);
  void dispatch_event(Locker&, Event::Type t, word) {
    CXXV_ASSERT(t == Event::DATA, "stop message is never dispatched");
    ++delivered;
  }
};
TimerEventSource* TimerEventSource::instance_;
ObservedInstance Ec618EventSource::instance_;
static Ec618EventSource* worker;
static bool unpublished() {
  return !TimerEventSource::instance_ && !Ec618EventSource::instance();
}
using BaseType_t = int;
static constexpr int pdFALSE = 0;
static void taskENTER_CRITICAL() { ++critical; }
static void taskEXIT_CRITICAL() {
  CXXV_ASSERT(critical != 0, "balanced task critical section");
  --critical;
}
static void portYIELD_FROM_ISR(int) { CXXV_ASSERT(in_isr, "ISR-only yield"); }
static int enqueue_data(int* queue, Event* event) {
  CXXV_ASSERT(!closing && !deleted && queue == &storage && event->type == Event::DATA,
              "producer touches only the open queue");
  if (queued == 32) return pdFALSE;
  ++queued;
  return pdTRUE;
}
static int xQueueSendFromISR(int* queue, Event* event, int* wake) {
  CXXV_ASSERT(in_isr && *wake == pdFALSE, "initialized ISR wake flag");
  return enqueue_data(queue, event);
}
static void producers() {
  unsigned prior = critical;
  task_producer = true;
  Ec618EventSource::send_event(Event::DATA, 0);
  task_producer = false;
  CXXV_ASSERT(critical == prior, "task producer restores prior critical nesting");
  in_isr = true;
  Ec618EventSource::send_event_from_isr(Event::DATA, 0);
  in_isr = false;
}
static int* xQueueCreate(unsigned count, unsigned size) {
  CXXV_ASSERT(count == 32 && size == sizeof(Event), "FIFO has the modeled capacity and item width");
  return allocated ? &storage : nullptr;
}
static int xQueueReceive(int* queue, Event* event, unsigned wait) {
  CXXV_ASSERT(queue == &storage && pending_stop && !stopped && wait == portMAX_DELAY,
              "shutdown receives on a live FIFO until its stop message");
  event->data = 0;
  event->type = queued ? Event::DATA : Event::STOP;
  if (queued) --queued;
  else stopped = true;
  return pdTRUE;
}
static int xQueueSend(int* queue, Event* event, unsigned wait) {
  if (event->type == Event::DATA) {
    CXXV_ASSERT(critical && !in_isr && wait == 0, "task send cannot block while holding the source");
    return enqueue_data(queue, event);
  }
  closing = true;
  producers();
  CXXV_ASSERT(queue == &storage && started && event->type == Event::STOP && wait == portMAX_DELAY,
              "live worker gets one blocking stop message");
  pending_stop = true;
  // When full, the worker must run to make space. Model the blocked send
  // appending STOP immediately after the first dequeue; all older entries
  // still precede it. It may finish before the sender resumes.
  if (queued == 32 || nondet_bool()) {
    worker->entry();
    CXXV_ASSERT(stopped, "worker drained through STOP before sender resumed");
  }
  return pdTRUE;
}
void Thread::join() {
  CXXV_ASSERT(started && pending_stop && !joined && !deleted, "join the live worker exactly once");
  producers();
  if (!stopped) worker->entry();
  CXXV_ASSERT(stopped, "worker consumed STOP before join returns");
  joined = true;
}
static void vQueueDelete(int* q) {
  CXXV_ASSERT(q == &storage && joined && !deleted, "release the FIFO only after join");
  deleted = true;
  producers();
}
#undef FATAL
#define FATAL(...) do { \
  CXXV_ASSERT((!allocated || !spawned) && !started && !TimerEventSource::instance_ && \
              !Ec618EventSource::instance(), "startup failure cannot publish a worker"); \
  CXXV_ASSUME(false); \
} while (false)
#include "event_worker_start.inc"
}

int main() {
  using namespace toit;
  allocated = nondet_bool();
  spawned = nondet_bool();
  if (nondet_bool()) {
    TimerEventSource timer;
    CXXV_ASSERT(started && timer.instance_ == &timer, "return only with a started timer");
  } else {
    unsigned initial = nondet_uint();
    CXXV_ASSUME(initial <= 32);
    queued = initial;
    alignas(Ec618EventSource) unsigned char slot[sizeof(Ec618EventSource)];
    auto source = new (slot) Ec618EventSource();
    worker = source;
    CXXV_ASSERT(started && source->instance() == source, "return only with a started peripheral worker");
    producers();
    unsigned admitted = queued;
    source->~Ec618EventSource();
    CXXV_ASSERT(delivered == admitted && deleted && !Ec618EventSource::instance(),
                "shutdown drains queued events and retires the singleton");
  }
}

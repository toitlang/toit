// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "resources/timer.cc"
#include "vm.h"
#include "scheduler.h"
#undef protected
#undef private

namespace toit {
static bool begin_timer_round();
static void checked_dispatch(const Locker& lock, Timer* timer, word data);
#include "timer_dispatch.inc"
}

using namespace toit;
extern TimerEventSource source;
extern Timer first_timer, second_timer;
// The loop starts with a live timer group. Registration is outside this gate.
ResourceGroup::ResourceGroup(Process* proc, EventSource* events) : process_(proc), event_source_(events) {}
extern VM vm;
extern Scheduler scheduler;
extern ObjectNotifier monitor;
extern Mutex source_mutex;
extern ConditionVariable changed;
VM* VM::current_ = &vm;

static Timer* const entries[] = {&first_timer, &second_timer};
static int64 deadlines[2], now;
static uint32 states[2];
static bool monitored[2], held, fresh, notifying, ran_round, sampled;
static unsigned count, delivered, waits, notifications;
static word tag;

// Cut at the next loop header. The postcondition below describes the queue
// and event state passed to the next round, including after a spurious wake.
bool toit::begin_timer_round() {
  if (ran_round) return false;
  ran_round = true;
  return true;
}

word OS::get_heap_tag() { return tag; }
void OS::set_heap_tag(word value) { tag = value; }

void Locker::enter() {
  CXXV_ASSERT(!held && mutex() == &source_mutex, "serialize timer dispatch on the source mutex");
  held = true;
}
void Locker::leave() {
  CXXV_ASSERT(held && mutex() == &source_mutex, "release the timer source mutex");
  held = false;
}

int64 OS::get_system_time() {
  CXXV_ASSERT(held && !sampled && delivered < count, "sample the clock with an armed timer");
  int64 next = nondet_int64();
  CXXV_ASSUME(now <= next);
  sampled = true;
  now = next;
  fresh = true;
  return now;
}

void Scheduler::send_notify_message(ObjectNotifier* notifier) {
  CXXV_ASSERT(held && notifying && this == &scheduler && notifier == &monitor &&
              delivered < count && monitored[delivered] &&
              entries[delivered]->state() == (states[delivered] | 1u),
              "notify the registered monitor after publishing the timer event");
  ++notifications;
}

void toit::checked_dispatch(const Locker& lock, Timer* timer, word data) {
  CXXV_ASSERT(held && lock.mutex() == &source_mutex && delivered < count &&
              timer == entries[delivered] && data == 0 && timer->timeout() <= now &&
              !source.timers_.is_linked(timer) && timer->state() == states[delivered],
              "unlink each due timer once in queue order before delivering its event");
  unsigned prior = notifications;
  notifying = true;
  source.dispatch(lock, timer, data);
  notifying = false;
  CXXV_ASSERT(timer->state() == (states[delivered] | 1u) &&
              notifications == prior + monitored[delivered], "set the ready bit and notify exactly its monitor");
  ++delivered;
  fresh = false;
}

static void wake(ConditionVariable* cv) {
  CXXV_ASSERT(held && cv == &changed && waits == 0, "wait once on the timer source condition");
  ++waits;
  source.stop_ = nondet_bool();
}
void OS::wait(ConditionVariable* cv) {
  CXXV_ASSERT(delivered == count && source.timers_.is_empty(), "wait indefinitely only after draining all timers");
  wake(cv);
}
bool OS::wait_us(ConditionVariable* cv, int64 remaining) {
  CXXV_ASSERT(fresh && delivered < count && source.timers_.first() == entries[delivered] &&
              deadlines[delivered] > now && remaining == deadlines[delivered] - now,
              "wait for the first future deadline using a fresh time sample");
  wake(cv);
  return nondet_bool();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  vm.scheduler_ = &scheduler;
  source.mutex_ = &source_mutex;
  source.timer_changed_ = &changed;
  new (&source.timers_) TimerList();
  bool stopped = nondet_bool();
  source.stop_ = stopped;
  auto* group = new TimerResourceGroup(nullptr, &source);
  count = nondet_uchar();
  CXXV_ASSUME(count <= 2);
  deadlines[0] = nondet_int64();
  deadlines[1] = nondet_int64();
  CXXV_ASSUME(deadlines[0] <= deadlines[1]);
  for (unsigned i = 0; i < count; ++i) {
    Timer* t = entries[i];
    new (static_cast<TimerList::Element*>(t)) TimerList::Element();
    t->set_timeout(deadlines[i]);
    states[i] = nondet_uint();
    t->set_state(states[i]);
    t->resource_group_ = group;
    monitored[i] = nondet_bool();
    t->set_object_notifier(monitored[i] ? &monitor : nullptr);
    source.timers_.append(t);
  }
  word prior_tag = nondet_word();
  tag = prior_tag;
  source.TimerEventSource::entry();
  CXXV_ASSERT(!held && tag == prior_tag && ran_round == !stopped && sampled == (!stopped && count > 0),
              "enter only a live round, sample a nonempty queue once, and restore the heap tag");
  unsigned due = 0;
  while (due < count && deadlines[due] <= now) ++due;
  CXXV_ASSERT(delivered == (stopped ? 0u : due) && waits == (!stopped && due == 0),
              "drain exactly the due prefix and immediately revisit the loop after delivery");
  auto* previous = &source.timers_.anchor_;
  for (unsigned i = delivered; i < count; ++i) {
    auto* link = static_cast<TimerList::Element*>(entries[i]);
    CXXV_ASSERT(previous->next_ == link && link->prev_ == previous, "retain the pending suffix in queue order");
    previous = link;
  }
  CXXV_ASSERT(previous->next_ == &source.timers_.anchor_ && source.timers_.anchor_.prev_ == previous,
              "close the remaining queue in both directions at the next loop header");
  for (unsigned i = 0; i < count; ++i) {
    CXXV_ASSERT(source.timers_.is_linked(entries[i]) == (i >= delivered) &&
                entries[i]->timeout() == deadlines[i] &&
                entries[i]->state() == (i < delivered ? states[i] | 1u : states[i]),
                "preserve each pending timer and retain the delivered event state");
  }
}

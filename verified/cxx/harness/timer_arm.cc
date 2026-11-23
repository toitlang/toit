// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "resources/timer.cc"
namespace toit {
#include "timer_queue.inc"
}
#undef protected
#undef private
#include "event_proxy.h"

using namespace toit;

extern Timer timer;
extern TimerEventSource clock_source;
extern Process caller;
extern HeapObject* program_null;

TimerEventSource* TimerEventSource::instance_ = nullptr;
extern Timer peer_a, peer_b;
extern Mutex source_mutex;
extern ConditionVariable changed;
static unsigned acquisitions, signals;
static bool held;

void Locker::enter() {
  CXXV_ASSERT(mutex() == &source_mutex && !held, "acquire the timer source mutex");
  held = true;
  ++acquisitions;
}

void Locker::leave() {
  CXXV_ASSERT(held && mutex() == &source_mutex, "release the same timer source mutex");
  held = false;
}

void OS::signal(ConditionVariable* cv) {
  CXXV_ASSERT(held && cv == &changed, "notify the timer thread under its mutex");
  ++signals;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  cxxv::EventProxy proxy;
  proxy.initialize(&timer);
  caller.null_ = program_null;

  uword boxed[1 + sizeof(int64) / sizeof(uword)];
  boxed[0] = nondet_ulong() & ~uword{1};
  int64 boxed_value = nondet_int64();
  memcpy(boxed + 1, &boxed_value, sizeof(boxed_value));
  bool immediate = nondet_bool();
  word small = nondet_word();
  CXXV_ASSUME(Smi::is_valid(small));
  Object* timeout = immediate ? static_cast<Object*>(Smi::from(small))
                              : static_cast<Object*>(HeapObject::from_address(reinterpret_cast<uword>(boxed)));
  bool integer = immediate || ((boxed[0] >> 1) & 15) == LARGE_INTEGER_TAG;
  int64 expected_deadline = immediate ? static_cast<int64>(small) : boxed_value;
  if (proxy.byte_array && nondet_bool()) {
    timeout = proxy.object;
    integer = false;
  }
  TimerEventSource::instance_ = &clock_source;
  clock_source.mutex_ = &source_mutex;
  clock_source.timer_changed_ = &changed;
  auto& queue = clock_source.timers_;
  new (&queue) TimerList();
  Timer* peers[] = {&peer_a, &peer_b};
  unsigned peer_count = nondet_uchar();
  CXXV_ASSUME(peer_count <= 2);
  int64 deadlines[] = {nondet_int64(), nondet_int64()};
  CXXV_ASSUME(deadlines[0] <= deadlines[1]);
  uint32 states[] = {nondet_uint(), nondet_uint()};
  bool linked = nondet_bool();
  unsigned old_index = nondet_uchar();
  CXXV_ASSUME(old_index <= peer_count);
  int64 old_timeout = nondet_int64();
  uint32 old_state = nondet_uint();
  new (static_cast<TimerList::Element*>(&timer)) TimerList::Element();
  timer.set_timeout(old_timeout);
  timer.set_state(old_state);
  for (unsigned i = 0; i < peer_count; ++i) {
    new (static_cast<TimerList::Element*>(peers[i])) TimerList::Element();
    peers[i]->set_timeout(deadlines[i]);
    peers[i]->set_state(states[i]);
    if (linked) {
      CXXV_ASSUME(i < old_index ? deadlines[i] <= old_timeout : old_timeout <= deadlines[i]);
      if (i == old_index) queue.append(&timer);
    }
    queue.append(peers[i]);
  }
  if (linked && old_index == peer_count) queue.append(&timer);
  bool was_empty = !linked && peer_count == 0;
  int64 old_first = linked && old_index == 0 ? old_timeout : deadlines[0];

  Object* frame[] = {timeout, proxy.object};
  Object* result = primitive_arm(&caller, frame + 1);
  int error = -1;
  if (!proxy.has_type(Timer::tag_min, Timer::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (!proxy.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (!integer) error = Program::WRONG_OBJECT_TYPE_INDEX;
  Object* expected = error < 0 ? static_cast<Object*>(program_null) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(result == expected && acquisitions == (error < 0 ? 1u : 0u),
              "arm once for a valid timer and integer, otherwise return the specified error");
  bool updated = error < 0 && (!linked || old_timeout != expected_deadline);
  CXXV_ASSERT(!held && signals == (updated && (was_empty || expected_deadline < old_first)),
              "wake exactly for an empty queue or a newly earlier deadline");
  CXXV_ASSERT(timer.timeout() == (updated ? expected_deadline : old_timeout) &&
              timer.state() == (updated ? 0u : old_state), "only a changed arm clears pending events");
  bool present = linked || updated;
  unsigned index = old_index;
  if (updated) {
    index = 0;
    while (index < peer_count && deadlines[index] <= expected_deadline) ++index;
  }
  auto* previous = &queue.anchor_;
  for (unsigned i = 0; i < peer_count + present; ++i) {
    Timer* item = present && i == index ? &timer : peers[i - (present && i > index)];
    auto* element = static_cast<TimerList::Element*>(item);
    CXXV_ASSERT(previous->next_ == element && element->prev_ == previous,
                "preserve both queue links and stable deadline order");
    previous = element;
  }
  CXXV_ASSERT(previous->next_ == &queue.anchor_ && queue.anchor_.prev_ == previous &&
              queue.is_linked(&timer) == present, "close the ring with exactly the expected members");
  for (unsigned i = 0; i < peer_count; ++i) {
    CXXV_ASSERT(peers[i]->timeout() == deadlines[i] && peers[i]->state() == states[i],
                "arming preserves other timers' deadlines and pending events");
  }
  CXXV_ASSERT(frame[0] == timeout && frame[1] == proxy.object, "preserve both argument slots");

  // Unregistration runs under the event source lock, including for a timer
  // which has already fired or was never armed.
  unsigned before_unregister = signals;
  {
    Locker lock(&source_mutex);
    clock_source.TimerEventSource::on_unregister_resource(lock, &timer);
  }
  CXXV_ASSERT(!held && signals == before_unregister + (present && index == 0) &&
              !queue.is_linked(&timer), "unregister wakes the timer thread only when removing its head");
  auto* detached = static_cast<TimerList::Element*>(&timer);
  CXXV_ASSERT(detached->prev_ == detached && detached->next_ == detached,
              "release both timer links before destruction");
  previous = &queue.anchor_;
  for (unsigned i = 0; i < peer_count; ++i) {
    auto* element = static_cast<TimerList::Element*>(peers[i]);
    CXXV_ASSERT(previous->next_ == element && element->prev_ == previous &&
                peers[i]->timeout() == deadlines[i] && peers[i]->state() == states[i],
                "unregister preserves the remaining queue and timer states");
    previous = element;
  }
  CXXV_ASSERT(previous->next_ == &queue.anchor_ && queue.anchor_.prev_ == previous,
              "the remaining queue closes at its original anchor");
}

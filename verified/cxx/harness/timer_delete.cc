// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "resources/timer.cc"
#undef private
#include "event_proxy.h"

using namespace toit;

extern Timer timer;
extern TimerResourceGroup group;
extern TimerResourceGroup other_group;
extern Process caller;
extern HeapObject* program_null;

static unsigned removals;
static word initial_count;
static cxxv::EventProxy* timer_proxy;

namespace toit {
// The resource lists, event-source lock and physical destruction are the
// unregister operation's contract. Observe the arguments and call order.
void ResourceGroup::unregister_resource(Resource* r) {
  CXXV_ASSERT(this == &group && r == &timer && r->resource_group() == this,
              "unregister the timer only through its owning group");
  CXXV_ASSERT(caller.timer_count_ == initial_count && timer_proxy->words[2] == reinterpret_cast<uword>(r),
              "unregister before changing the quota or closing the proxy");
  ++removals;
}
}  // namespace toit

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  cxxv::EventProxy g, t;
  g.initialize(&group);
  t.initialize(&timer);
  timer_proxy = &t;
  const cxxv::EventProxy& second = nondet_bool() ? g : t;
  bool belongs = nondet_bool();
  timer.resource_group_ = belongs ? &group : &other_group;
  initial_count = nondet_word();
  CXXV_ASSUME(initial_count >= 0);
  caller.timer_count_ = initial_count;
  caller.null_ = program_null;
  Object* frame[] = {second.object, g.object};
  uword original = t.words[2];
  Object* result = primitive_delete(&caller, frame + 1);

  int error = -1;
  if (!g.has_type(TimerResourceGroup::tag_min, TimerResourceGroup::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (!g.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (!second.has_type(Timer::tag_min, Timer::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (!second.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (!belongs) error = Program::WRONG_OBJECT_TYPE_INDEX;
  Object* expected = error < 0 ? static_cast<Object*>(program_null) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(result == expected && removals == (error < 0 ? 1u : 0u), "unregister once on success only");
  CXXV_ASSERT(t.words[2] == (error < 0 ? 0 : original), "close only a successfully deleted timer");
  word expected_count = error < 0 && initial_count > 0 ? initial_count - 1 : initial_count;
  CXXV_ASSERT(caller.timer_count_ == expected_count, "release one quota slot on success without underflow");
  CXXV_ASSERT(frame[0] == second.object && frame[1] == g.object, "preserve both arguments");

  if (error < 0) {
    Object* retry = primitive_delete(&caller, frame + 1);
    uword closed = (static_cast<uword>(Program::ALREADY_CLOSED_INDEX) << Error::ERROR_SHIFT) | Error::ERROR_TAG;
    CXXV_ASSERT(reinterpret_cast<uword>(retry) == closed && removals == 1 && caller.timer_count_ == expected_count,
                "repeated deletion reports closure without releasing another quota slot");
  }
}

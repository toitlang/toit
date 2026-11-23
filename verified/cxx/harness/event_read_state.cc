// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "primitive_events.cc"
#include "resource.cc"
#include "resources/timer.cc"
#undef private
#include "event_proxy.h"

using namespace toit;

extern ResourceGroup group;
extern ResourceGroup other_group;
extern Resource resource;
extern EventSource source;
extern Mutex source_mutex;
extern Process caller;
extern TimerResourceGroup timer_group;

static unsigned acquisitions;
static bool held;
static uint32_t at_acquisition;
static uint32_t after_release;

namespace toit {
// Other event producers may change the state immediately before acquisition
// and immediately after release. The critical section sees the former.
void Locker::enter() {
  CXXV_ASSERT(!held && mutex() == &source_mutex, "acquire the owning event source mutex");
  held = true;
  ++acquisitions;
  resource.set_state(at_acquisition);
}

void Locker::leave() {
  CXXV_ASSERT(held && mutex() == &source_mutex && resource.state() == 0,
              "clear the resource before releasing its event source mutex");
  held = false;
  resource.set_state(after_release);
}
}  // namespace toit

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Timer timer(&timer_group);
  CXXV_ASSERT(timer.state() == 0, "a new timer starts with a representable empty mask");
  uint32_t prior = nondet_uint();
  uint32_t ready = timer_group.TimerResourceGroup::on_event(&timer, nondet_word(), prior);
  CXXV_ASSERT(ready == (prior | 1u), "timer notification sets only bit zero");
  cxxv::EventProxy group_proxy, resource_proxy;
  group_proxy.initialize(&group);
  resource_proxy.initialize(&resource);
  const cxxv::EventProxy& r = nondet_bool() ? group_proxy : resource_proxy;
  bool belongs = nondet_bool();
  bool has_source = nondet_bool();
  group.event_source_ = has_source ? &source : nullptr;
  resource.resource_group_ = belongs ? &group : &other_group;
  source.mutex_ = &source_mutex;
  uint32_t before = nondet_uint();
  resource.set_state(before);
  at_acquisition = nondet_uint();
  after_release = nondet_uint();

  Object* frame[] = {r.object, group_proxy.object};
  Object* result = primitive_read_state(&caller, frame + 1);
  int error = -1;
  if (!group_proxy.has_type(ResourceGroup::tag_min, ResourceGroup::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (!group_proxy.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (!r.has_type(Resource::tag_min, Resource::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (!r.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (!belongs || !has_source) error = Program::WRONG_OBJECT_TYPE_INDEX;

  CXXV_ASSERT(!held && acquisitions == (error < 0 ? 1u : 0u), "lock exactly once on success and never on rejection");
  CXXV_ASSERT(frame[0] == r.object && frame[1] == group_proxy.object, "read preserves both argument slots");
  if (error >= 0) {
    uword marked = (static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG;
    CXXV_ASSERT(reinterpret_cast<uword>(result) == marked && resource.state() == before,
                "reject with the specified error and preserve state");
  } else {
    CXXV_ASSERT(reinterpret_cast<uword>(result) == (static_cast<uword>(at_acquisition) << 1),
                "return the tagged bits of the state observed while locked");
    if (at_acquisition <= static_cast<uword>(Smi::MAX_SMI_VALUE)) {
      CXXV_ASSERT(Smi::value(Smi::cast(result)) == static_cast<word>(at_acquisition),
                  "a representable event mask round-trips exactly");
    }
    CXXV_ASSERT(resource.state() == after_release, "preserve updates after releasing the mutex");
  }
}

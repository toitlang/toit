// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "primitive_events.cc"
#undef private
#include "event_proxy.h"

using namespace toit;

extern Process caller;
extern ResourceGroup group;
extern ResourceGroup other_group;
extern Resource resource;
extern EventSource source;
extern Object* arbitrary_reference();
extern HeapObject* program_null;

enum class Operation { REGISTER, UNREGISTER };
static Operation operation;
static Object* monitor;
static bool update_succeeds;
static unsigned calls;

namespace toit {
// Model the event-source operations at the boundary where synchronization,
// notifier ownership and scheduler delivery begin.
bool EventSource::update_resource_monitor(Resource* r, Process* p, Object* m) {
  CXXV_ASSERT(operation == Operation::REGISTER && this == &source && r == &resource &&
              p == &caller && m == monitor, "register on the owning source with the original arguments");
  ++calls;
  return update_succeeds;
}

void EventSource::delete_resource_monitor(Resource* r) {
  CXXV_ASSERT(operation == Operation::UNREGISTER && this == &source && r == &resource,
              "delete on the owning source for the supplied resource");
  ++calls;
}
}  // namespace toit

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(ResourceGroup::tag_max < Resource::tag_min || Resource::tag_max < ResourceGroup::tag_min,
                "resource and group proxy types are disjoint");
  cxxv::EventProxy group_proxy, resource_proxy;
  group_proxy.initialize(&group);
  resource_proxy.initialize(&resource);
  bool alias = nondet_bool();
  const cxxv::EventProxy& r = alias ? group_proxy : resource_proxy;
  bool belongs = nondet_bool();
  bool has_source = nondet_bool();
  group.event_source_ = has_source ? &source : nullptr;
  resource.resource_group_ = belongs ? &group : &other_group;
  caller.null_ = program_null;
  monitor = arbitrary_reference();
  update_succeeds = nondet_bool();
  operation = nondet_bool() ? Operation::REGISTER : Operation::UNREGISTER;
  bool registering = operation == Operation::REGISTER;
  Object* result;
  if (registering) {
    Object* frame[] = {r.object, group_proxy.object, monitor};
    result = primitive_register_monitor_notifier(&caller, frame + 2);
    CXXV_ASSERT(frame[0] == r.object && frame[1] == group_proxy.object && frame[2] == monitor,
                "registration preserves its three argument slots");
  } else {
    Object* frame[] = {r.object, group_proxy.object};
    result = primitive_unregister_monitor_notifier(&caller, frame + 1);
    CXXV_ASSERT(frame[0] == r.object && frame[1] == group_proxy.object,
                "unregistration preserves its two argument slots");
  }
  int error = -1;
  bool invoke = false;
  if (!group_proxy.has_type(ResourceGroup::tag_min, ResourceGroup::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (registering && !group_proxy.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (!r.has_type(Resource::tag_min, Resource::tag_max)) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (registering && !r.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (group_proxy.live && r.live) {
    if (!belongs || !has_source) error = Program::WRONG_OBJECT_TYPE_INDEX;
    else {
      invoke = true;
      if (registering && !update_succeeds) error = Program::MALLOC_FAILED_INDEX;
    }
  }
  Object* expected = error < 0 ? static_cast<Object*>(program_null) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(result == expected, "return the specified error or program null");
  CXXV_ASSERT(calls == static_cast<unsigned>(invoke), "call the event source exactly once only for an open matching pair");
}

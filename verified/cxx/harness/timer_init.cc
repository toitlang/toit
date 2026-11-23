// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "resource.cc"
#include "event_sources/timer.h"

using namespace toit;

extern Process caller;
extern TimerEventSource clock_source;

static uword proxy_words[4];
static ByteArray* proxy;
static bool heap_failure;
static bool permitted;
static bool group_failure;
static unsigned proxy_requests;
static unsigned quota_checks;
static unsigned group_requests;
static unsigned registrations;
static ResourceGroup* registered;
static void* group_storage;

static bool group_allocation_fails() {
  CXXV_ASSERT(quota_checks == 1 && permitted, "allocate a group only after quota admission");
  ++group_requests;
  return group_failure;
}

// Model nonthrowing allocation as null or fresh, aligned storage. The
// successful path executes the native derived and base constructors.
#undef _new
#define _new group_allocation_fails() ? nullptr : new (group_storage)
#include "resources/timer.cc"
#undef _new

namespace toit {
TimerEventSource* TimerEventSource::instance_ = &clock_source;

ByteArray* ObjectHeap::allocate_external_byte_array(word length, uint8* address, bool dispose, bool clear) {
  CXXV_ASSERT(this == caller.object_heap() && length == 0 && address == nullptr && !dispose && !clear,
              "allocate an empty external proxy from the caller's heap");
  ++proxy_requests;
  return heap_failure ? nullptr : proxy;
}

bool Process::may_add_permanent_resource_group() {
  CXXV_ASSERT(this == &caller && proxy_requests == 1 && !heap_failure, "check the caller's quota after proxy allocation");
  ++quota_checks;
  return permitted;
}

void Process::add_resource_group(ResourceGroup* group) {
  CXXV_ASSERT(this == &caller && group->process() == &caller && group->event_source() == &clock_source,
              "register a group initialized with the caller and timer source");
  CXXV_ASSERT(group_requests == 1 && !group_failure && proxy_words[2] == 0, "register before publishing the proxy");
  ++registrations;
  registered = group;
}
}  // namespace toit

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  group_storage = malloc(sizeof(TimerResourceGroup));
  CXXV_ASSUME(group_storage != nullptr);
  proxy_words[0] = 2 * BYTE_ARRAY_TAG;
  proxy_words[1] = UINTPTR_MAX;
  proxy_words[2] = 0;
  proxy_words[3] = NullStructTag;
  proxy = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(proxy_words)));
  heap_failure = nondet_bool();
  permitted = nondet_bool();
  group_failure = nondet_bool();
  Object* result = primitive_init(&caller, nullptr);
  int error = -1;
  if (heap_failure) error = Program::ALLOCATION_FAILED_INDEX;
  else if (!permitted) error = Program::QUOTA_EXCEEDED_INDEX;
  else if (group_failure) error = Program::MALLOC_FAILED_INDEX;
  Object* expected = error < 0 ? static_cast<Object*>(proxy) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(result == expected && proxy_requests == 1, "return the proxy or the precise initialization error");
  CXXV_ASSERT(quota_checks == static_cast<unsigned>(!heap_failure) &&
              group_requests == static_cast<unsigned>(!heap_failure && permitted), "reject before the next allocation");
  CXXV_ASSERT(registrations == static_cast<unsigned>(error < 0), "only successful initialization registers a group");
  if (error < 0) {
    CXXV_ASSERT(registered != nullptr, "registration retains a non-null group");
    CXXV_ASSERT(proxy_words[2] == reinterpret_cast<uword>(static_cast<TimerResourceGroup*>(registered)), "publish the registered group");
    CXXV_ASSERT(proxy_words[3] == TimerResourceGroup::tag, "publish the exact timer-group tag");
  } else {
    CXXV_ASSERT(proxy_words[2] == 0 && proxy_words[3] == NullStructTag, "failed initialization leaves the proxy unpublished");
  }
}

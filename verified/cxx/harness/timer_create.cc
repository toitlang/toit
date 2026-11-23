// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "process.h"
#include "event_sources/timer.h"
#undef private
#include "event_proxy.h"

using namespace toit;

static Process* caller;
static PrimitivePolicy policy;
static word initial_count;
static word limit;
static bool heap_failure;
static bool timer_failure;
static unsigned proxy_requests;
static unsigned timer_requests;
static unsigned registrations;
static uword proxy_words[4];
static ByteArray* proxy;
static void* timer_storage;
static Timer* registered;

static bool timer_allocation_fails() {
  CXXV_ASSERT(proxy_requests == 1 && !heap_failure, "allocate a timer only after obtaining its proxy");
  CXXV_ASSERT((limit == 0 || initial_count < limit) && caller->timer_count_ == initial_count + 1,
              "reserve one allowed quota slot before native timer allocation");
  ++timer_requests;
  return timer_failure;
}

// Model nonthrowing allocation by returning null or fresh aligned storage.
// The successful path executes the native Timer and Resource constructors.
#undef _new
#define _new timer_allocation_fails() ? nullptr : new (timer_storage)
#include "resources/timer.cc"
#undef _new

extern TimerResourceGroup group;
namespace toit {
// Set up the pre-existing caller with its immutable policy. The heap
// allocator below is modeled and never reads the heap's internal fields.
Process::Process(ProcessRunner*, ProcessGroup*, SystemMessage*)
    : id_(0), policy_(&::policy), entry_(Method::invalid()), spawn_method_(Method::invalid()), object_heap_(nullptr, this) {}

ByteArray* ObjectHeap::allocate_external_byte_array(word length, uint8* address, bool dispose, bool clear) {
  CXXV_ASSERT(this == caller->object_heap() && length == 0 && address == nullptr && !dispose && !clear,
              "request an empty external proxy from the calling process");
  CXXV_ASSERT(caller->timer_count_ == initial_count, "allocate the proxy before reserving quota");
  ++proxy_requests;
  return heap_failure ? nullptr : proxy;
}

void ResourceGroup::register_resource(Resource* r) {
  CXXV_ASSERT(this == &group && r->resource_group() == this && r->state() == 0 && r->object_notifier() == nullptr,
              "register the new timer with its supplied group and initial state");
  registered = static_cast<Timer*>(r);
  CXXV_ASSERT(registered->timeout() == -1 && static_cast<void*>(registered) == timer_storage,
              "register the unarmed timer constructed in the fresh allocation");
  CXXV_ASSERT(timer_requests == 1 && !timer_failure && proxy_words[2] == 0, "register before publishing the address");
  ++registrations;
}
}  // namespace toit

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  void* process_storage = malloc(sizeof(Process));
  CXXV_ASSUME(process_storage != nullptr);
  caller = new (process_storage) Process(nullptr, nullptr, nullptr);
  initial_count = nondet_word();
  limit = nondet_word();
  CXXV_ASSUME(initial_count >= 0 && limit >= 0);
  // Each live timer occupies at least sizeof(Timer) bytes of address space.
  CXXV_ASSUME(static_cast<uword>(initial_count) <= UINTPTR_MAX / sizeof(Timer));
  caller->timer_count_ = initial_count;
  policy.quotas_.max_timers = limit;

  timer_storage = malloc(sizeof(Timer));
  CXXV_ASSUME(timer_storage != nullptr);
  cxxv::EventProxy input;
  input.initialize(&group);
  proxy_words[0] = 2 * BYTE_ARRAY_TAG;
  proxy_words[1] = UINTPTR_MAX;
  proxy_words[2] = 0;
  proxy_words[3] = NullStructTag;
  proxy = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(proxy_words)));
  heap_failure = nondet_bool();
  timer_failure = nondet_bool();
  Object* frame[] = {input.object};
  Object* result = primitive_create(caller, frame);

  bool typed = input.has_type(TimerResourceGroup::tag_min, TimerResourceGroup::tag_max);
  bool admitted = limit == 0 || initial_count < limit;
  int error = -1;
  if (!typed) error = Program::WRONG_OBJECT_TYPE_INDEX;
  else if (!input.live) error = Program::ALREADY_CLOSED_INDEX;
  else if (heap_failure) error = Program::ALLOCATION_FAILED_INDEX;
  else if (!admitted) error = Program::QUOTA_EXCEEDED_INDEX;
  else if (timer_failure) error = Program::MALLOC_FAILED_INDEX;
  Object* expected = error < 0 ? static_cast<Object*>(proxy) :
      reinterpret_cast<Object*>((static_cast<uword>(error) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
  CXXV_ASSERT(result == expected && frame[0] == input.object, "return the proxy or the specified error and preserve the argument");
  CXXV_ASSERT(proxy_requests == static_cast<unsigned>(typed && input.live) &&
              timer_requests == static_cast<unsigned>(typed && input.live && !heap_failure && admitted),
              "only validated and admitted requests reach their respective allocations");
  CXXV_ASSERT(registrations == static_cast<unsigned>(error < 0) &&
              caller->timer_count_ == initial_count + (error < 0 ? 1 : 0), "charge and register once only on success");
  if (error < 0) {
    CXXV_ASSERT(registered != nullptr && proxy_words[2] == reinterpret_cast<uword>(registered) &&
                proxy_words[3] == Timer::tag, "publish the registered timer with its timer tag");
  } else {
    CXXV_ASSERT(proxy_words[2] == 0 && proxy_words[3] == NullStructTag, "failure leaves the native timer unpublished");
  }
}

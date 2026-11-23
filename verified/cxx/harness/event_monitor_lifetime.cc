// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#include "primitive.h"
#undef protected
#undef private

using namespace toit;
extern EventSource source;
extern Resource watched;
extern Process receiver;
extern Mutex source_mutex, mailbox;
extern VM vm;
extern Scheduler scheduler;
extern Object* arbitrary_reference();
VM* VM::current_ = &vm;
Mutex* OS::process_mutex_ = &mailbox;
static unsigned allocations, fail_at, sends;
static bool source_held, mailbox_held;
static ObjectNotifier* allocate_root(Process* process, Object* monitor) {
  if (++allocations == fail_at) return nullptr;
  void* storage = malloc(sizeof(ObjectNotifier));
  CXXV_ASSUME(storage != nullptr);
  return new (storage) ObjectNotifier(process, monitor);
}
static ObjectNotifyMessage* allocate_message(ObjectNotifier* notifier) {
  if (++allocations == fail_at) return nullptr;
  return new ObjectNotifyMessage(notifier);
}

// Spell out the destructor and storage release for the placement-constructed root.
static void destroy_root(ObjectNotifier* n) {
  n->~ObjectNotifier();
  free(n);
}

namespace toit {
#include "monitor_lifetime.inc"
}

void Locker::enter() {
  if (mutex() == &source_mutex) {
    CXXV_ASSERT(!source_held && !mailbox_held, "serialize monitor registration and cancellation");
    source_held = true;
  } else {
    CXXV_ASSERT(mutex() == &mailbox && !mailbox_held, "serialize the notification message links");
    mailbox_held = true;
  }
}
void Locker::leave() {
  if (mutex() == &source_mutex) {
    CXXV_ASSERT(source_held && !mailbox_held, "finish monitor publication before releasing the source mutex");
    source_held = false;
  } else {
    CXXV_ASSERT(mailbox_held, "release the mailbox mutex");
    mailbox_held = false;
  }
}

// Give an immediately ready registration the live-receiver behavior of
// scheduler-notify. Worker scheduling does not change notifier ownership.
void Scheduler::send_notify_message(ObjectNotifier* n) {
  CXXV_ASSERT(this == &scheduler && source_held && n == watched.object_notifier() &&
              n->process() == &receiver && n->message()->object_notifier() == n,
              "publish the complete monitor and message before sending");
  bool accepted = receiver._append_message(n->message());
  CXXV_ASSERT(accepted, "accept a live monitor without quota charges");
  ++sends;
}

// The monitor-scavenge gate proves this root callback's postcondition for
// a young leaf and optional global alias. Collection is serialized here.
class ForwardMonitor : public RootCallback {
 public:
  ForwardMonitor(Object* from, Object* to) : from_(from), to_(to) {}

  void do_roots(Object** slot, word count) override {
    CXXV_ASSERT(!visited && count == 1 && *slot == from_, "visit the registered monitor value once");
    *slot = to_;
    visited = true;
  }
  bool visited = false;

 private:
  Object* from_;
  Object* to_;
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  vm.scheduler_ = &scheduler;
  source.mutex_ = &source_mutex;
  watched.set_object_notifier(nullptr);
  new (&receiver.messages_) MessageFIFO();
  auto& roots = receiver.object_heap()->object_notifiers_;
  new (&roots) ObjectNotifierList();
  fail_at = nondet_uchar();  // 1 fails the root, 2 fails its message.
  Object* original = arbitrary_reference();
  Object* replacement = arbitrary_reference();
  Object* survivor = arbitrary_reference();
  new (&receiver.object_heap()->runnable_finalizers_) FinalizerNodeFifo();
  uword null_storage[1];
  receiver.null_ = HeapObject::from_address(reinterpret_cast<uword>(null_storage));
  uint32 state = nondet_uint();
  watched.set_state(state);
  bool ok = source.update_resource_monitor(&watched, &receiver, original);
  CXXV_ASSERT(ok == (fail_at != 1 && fail_at != 2) && allocations == (fail_at == 1 ? 1 : 2),
              "propagate either native allocation failure");
  ObjectNotifier* n = watched.object_notifier();
  CXXV_ASSERT(roots.first() == n && roots.last() == n && (n != nullptr) == ok,
              "registration publishes exactly its GC root and rolls it back on failure");
  if (ok) {
    ObjectNotifyMessage* message = n->message();
    CXXV_ASSERT(n->object() == original && message->is_queued() == (state != 0) &&
                receiver.messages_.first() == (state ? message : nullptr),
                "retain the registered object and deliver an already pending event");
    uint32 later = nondet_uint();
    watched.set_state(later);
    bool updated = source.update_resource_monitor(&watched, &receiver, replacement);
    bool queued = state || later;
    CXXV_ASSERT(updated && watched.object_notifier() == n && n->object() == replacement && n->message() == message &&
                allocations == 2 && message->is_queued() == queued && sends == (state != 0) + (later != 0),
                "replace the monitored root without replacing the reusable message");
    ForwardMonitor collection(replacement, survivor);
    n->roots_do(&collection);
    CXXV_ASSERT(collection.visited && n->object() == survivor && n->message() == message &&
                message->object_notifier() == n && message->is_queued() == queued,
                "update only the monitor root while preserving its native mailbox link");
    if (queued && nondet_bool()) {
      Object* received = primitive_task_receive_message(&receiver, nullptr);
      CXXV_ASSERT(received == survivor && !message->is_queued(), "receive the relocated monitor and release its message");
      queued = false;
    }
    source.delete_resource_monitor(&watched);
    if (queued) {
      CXXV_ASSERT(receiver.messages_.first() == message && message->object_notifier() == nullptr && message->is_queued(),
                  "leave an enqueued canceled notification alive until the receiver removes it");
      Object* received = primitive_task_receive_message(&receiver, nullptr);
      CXXV_ASSERT(received == receiver.null_object(), "return program null for a canceled monitor after relocation");
    }
  } else {
    CXXV_ASSERT(!sends, "failed registration does not send");
  }
  source.delete_resource_monitor(&watched);
  CXXV_ASSERT(!source_held && !mailbox_held && !watched.object_notifier() && roots.is_empty() &&
              receiver.messages_.is_empty(), "finish with neither a notifier root nor a mailbox entry");
}

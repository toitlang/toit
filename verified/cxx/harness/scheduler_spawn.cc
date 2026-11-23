// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process_group.cc"
#include "process.cc"
#include "messaging.cc"
#include "objects_runtime.cc"
#include "heap.cc"
#undef protected
#undef private

namespace toit {
static Process* construct_process(Program*, ProcessGroup*, SystemMessage*, Method, InitialMemoryManager*);
static void destroy_notice(SystemMessage*);
#include "scheduler_spawn.inc"
}

using namespace toit;
extern Scheduler scheduler;
extern Process child, sender, peer;
extern SystemMessage termination, spawned;
static MessageEncoder* active_encoder;
extern Program image;
extern InitialMemoryManager memory;
static ProcessGroup* owner;
static int failure, attempts, registered;
static bool held, sent, accepted, scheduled;
static bool freed_termination, freed_spawned;
static uint8 argument, copy, payload;

void Locker::enter() { held = true; }
void Locker::leave() { held = false; }
SystemMessage* Scheduler::new_process_message(SystemMessage::Type type, int gid) {
  CXXV_ASSERT(held && !registered && gid == owner->id(), "reserve notifications before registering a child");
  ++attempts;
  CXXV_ASSERT((attempts == 1 && type == SystemMessage::TERMINATED) ||
              (attempts == 2 && type == SystemMessage::SPAWNED), "reserve both notices in order");
  return attempts == failure ? nullptr : attempts == 1 ? &termination : &spawned;
}

Process* toit::construct_process(Program* p, ProcessGroup* g, SystemMessage* msg, Method, InitialMemoryManager* m) {
  CXXV_ASSERT(held && attempts == 2 && failure != 1 && failure != 2 && !registered &&
              p == &image && g == owner && m == &memory && msg == &termination,
              "construct the child only after acquiring both notifications");
  CXXV_ASSERT(active_encoder->buffer_ == &argument && child.spawn_arguments() == nullptr,
              "the sender retains the argument buffer until construction succeeds");
  if (failure == 3) return nullptr;
  owner->add(&child);
  ++registered;
  return &child;
}
void toit::destroy_notice(SystemMessage* msg) {
  CXXV_ASSERT(held && (msg == &termination || msg == &spawned), "destroy a reserved notice under lock");
  if (msg == &termination) {
    CXXV_ASSERT(attempts == 2 && !registered && !freed_termination, "release an untransferred termination notice once");
    freed_termination = true;
  } else {
    CXXV_ASSERT(attempts == 2 && failure != 2 && !freed_spawned && (!registered || (sent && !accepted)),
                "release only an undelivered spawn notice once");
    freed_spawned = true;
  }
}
message_err_t Scheduler::send_system_message(Locker&, SystemMessage* msg) {
  CXXV_ASSERT(held && registered && active_encoder->buffer_ == nullptr && child.spawn_arguments() == &argument && !sent && msg == &spawned && msg->pid() == child.id(),
              "announce the registered child with its assigned pid");
  sent = true;
  return accepted ? MESSAGE_OK : MESSAGE_QUOTA_EXCEEDED;
}
void Scheduler::new_process(Locker&, Process* p) {
  CXXV_ASSERT(held && sent && !scheduled && p == &child && p->spawn_arguments_ == &argument,
              "schedule the child after the notification attempt");
  scheduled = true;
}
int main() {
  PrimitivePolicy policy;
  owner = new ProcessGroup(42, &image, nullptr, &policy);
  CXXV_ASSUME(owner != nullptr);
  bool has_peer = nondet_bool();
  if (has_peer) owner->add(&peer);
  bool limited = nondet_bool();
  policy.quotas_.max_processes = limited ? 1 : 0;
  bool exhausted = nondet_bool();
  scheduler.next_process_id_ = exhausted ? Scheduler::INVALID_PROCESS_ID : 17;
  bool refused = exhausted || (limited && has_peer);
  failure = nondet_uint() % 4;
  accepted = nondet_bool();
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  child.spawn_arguments_ = nullptr;
  child.main_arguments_ = &copy;
  bool transfer = nondet_bool();
  unsigned copies = nondet_uint(), witness = nondet_uint();
  CXXV_ASSUME(copies <= MESSAGING_ENCODING_MAX_EXTERNALS - static_cast<unsigned>(transfer));
  CXXV_ASSUME(witness < MESSAGING_ENCODING_MAX_EXTERNALS);
  active_encoder = new MessageEncoder(&sender, &argument);
  CXXV_ASSUME(active_encoder != nullptr);
  MessageEncoder& encoder = *active_encoder;
  encoder.transferred_count_ = transfer;
  encoder.copied_count_ = copies;
  encoder.copied_[witness] = &copy;
  uword words[ByteArray::EXTERNAL_SIZE / WORD_SIZE] = {2 * BYTE_ARRAY_TAG};
  auto* array = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  word length = nondet_word();
  uword charged = nondet_ulong();
  CXXV_ASSUME(length >= 0 && static_cast<uword>(length) <= charged);
  sender.object_heap()->external_memory_.store(charged);
  array->_initialize_external_memory(length, &payload, false);
  array->set_has_active_finalizer();
  encoder.transferred_[0] = array;

  int pid = scheduler.spawn(&image, owner, -1, Method::invalid(), &encoder, &memory);
  bool ok = !refused && failure == 0;
  CXXV_ASSERT(attempts == (refused ? 0 : failure == 1 ? 1 : 2), "check quota and pid exhaustion before allocating notices");
  int expected_pid = refused ? Scheduler::QUOTA_EXCEEDED_PROCESS_ID : ok ? child.id() : Scheduler::INVALID_PROCESS_ID;
  CXXV_ASSERT(!held && registered == ok && scheduled == ok && sent == ok &&
              owner->processes_.first() == (ok ? &child : has_peer ? &peer : nullptr) &&
              pid == expected_pid, "failed admission leaves no child and transfers no arguments");
  CXXV_ASSERT(encoder.buffer_ == (ok ? nullptr : &argument) && child.spawn_arguments() == (ok ? &argument : nullptr) &&
              child.main_arguments() == &copy, "move the buffer into only the admitted child's spawn slot");
  CXXV_ASSERT(encoder.copied_[witness] == (ok && witness < copies ? nullptr : &copy),
              "disarm each owned copy only on publication");
  bool moved = ok && transfer;
  CXXV_ASSERT(array->as_external() == (moved ? nullptr : &payload) && array->_external_length() == (moved ? 0 : length) &&
              array->has_active_finalizer() == !moved && sender.object_heap()->external_memory() ==
              charged - (moved ? static_cast<uword>(length) : 0), "detach and refund transferred storage only on admission");
  CXXV_ASSERT(freed_termination == (!refused && (failure == 2 || failure == 3)) &&
              freed_spawned == ((!refused && failure == 3) || (ok && !accepted)), "balance notification ownership on every allocation outcome");
}

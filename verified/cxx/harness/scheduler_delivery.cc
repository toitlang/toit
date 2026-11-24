// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#include "process_group.cc"
#undef protected
#undef private
#include "hw_perf.h"
namespace toit {
static void cxxv_destroy(SystemMessage* message);
#include "send_message_from.inc"
}

using namespace toit;
extern VM vm;
extern Scheduler scheduler;
extern Mutex scheduler_mutex, mailbox_mutex;
VM* VM::current_ = &vm;
Mutex* OS::process_mutex_ = &mailbox_mutex;
static Process* destination;
static Process* lookup_result;
static SystemMessage* incoming;
static int requested;
static unsigned lookups, decodes, shutdowns, wakes, destructions, mailbox_entries;
static bool routing, in_mailbox;
static int exit_value;
static bool decodable;

int Scheduler::next_process_id() {
  static int next = 11;
  return next++;
}

void Locker::enter() {
  if (mutex() == &scheduler_mutex) {
    CXXV_ASSERT(!routing && !in_mailbox, "take the scheduler lock first");
    routing = true;
  } else {
    CXXV_ASSERT(mutex() == &mailbox_mutex && routing && !in_mailbox, "acquire the receiver lock under the scheduler lock");
    in_mailbox = true;
    ++mailbox_entries;
  }
}

void Locker::leave() {
  CXXV_ASSERT(routing, "release only a held lock");
  if (mutex() == &scheduler_mutex) {
    CXXV_ASSERT(!in_mailbox, "release the receiver lock before the scheduler lock");
    routing = false;
  } else {
    CXXV_ASSERT(in_mailbox, "release the held mailbox mutex");
    in_mailbox = false;
  }
}

Process* Scheduler::find_process(Locker& lock, int pid) {
  CXXV_ASSERT(lock.mutex() == &scheduler_mutex && routing && pid == requested && pid >= 0,
              "look up the requested nonnegative pid under the scheduler lock");
  ++lookups;
  return lookup_result;
}

bool MessageDecoder::decode_process_message(const uint8* data, int* value) {
  CXXV_ASSERT(routing && requested < 0 && scheduler.boot_process_ == nullptr && incoming->type() == SYSTEM_TERMINATED &&
              data == incoming->data(), "decode only the termination payload when no boot process handles it");
  ++decodes;
  if (decodable) *value = exit_value;
  return decodable;
}

void Scheduler::terminate_execution(Locker& lock, ExitState exit) {
  CXXV_ASSERT(lock.mutex() == &scheduler_mutex && routing && decodable && decodes == 1 &&
              exit.value == exit_value && exit.reason == (exit_value == 0 ? EXIT_DONE : EXIT_ERROR),
              "shut down with the exact decoded value and reason");
  ++shutdowns;
}

void Scheduler::process_ready(Locker& lock, Process* process) {
  CXXV_ASSERT(lock.mutex() == &scheduler_mutex && routing && !in_mailbox &&
              process == (requested < 0 ? scheduler.boot_process_ : destination) &&
              process->messages_.tail_ == static_cast<MessageFIFO::Element*>(incoming),
              "wake the intended receiver after publishing its message");
  ++wakes;
}

void toit::cxxv_destroy(SystemMessage* message) {
  CXXV_ASSERT(routing && !in_mailbox && message == incoming && wakes == 0 && destructions == 0,
              "hand the undelivered message to its destructor once under the scheduler lock");
  ++destructions;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  vm.scheduler_ = &scheduler;
  scheduler.mutex_ = &scheduler_mutex;
  PrimitivePolicy sender_policy, destination_policy;
  bool restricted = nondet_bool(), other_restricted = nondet_bool();
  sender_policy.kind_ = restricted ? PrimitivePolicy::UNTRUSTED : PrimitivePolicy::TRUSTED;
  destination_policy.kind_ = other_restricted ? PrimitivePolicy::UNTRUSTED : PrimitivePolicy::TRUSTED;
  sender_policy.quotas_.max_mailbox_messages = destination_policy.quotas_.max_mailbox_messages = 1;
  bool grant_room = nondet_bool();
  destination_policy.quotas_.max_send_grants = grant_room ? 2 : 1;
  auto* origin = new ProcessGroup(1, nullptr, nullptr, &sender_policy);
  auto* other = new ProcessGroup(2, nullptr, nullptr, &destination_policy);
  CXXV_ASSUME(origin != nullptr && other != nullptr);
  bool same = nondet_bool();
  auto* recipient_group = same ? origin : other;
  auto* sender = new Process(static_cast<ProcessRunner*>(nullptr), origin, nullptr);
  destination = new Process(static_cast<ProcessRunner*>(nullptr), recipient_group, nullptr);
  CXXV_ASSUME(sender != nullptr && destination != nullptr);
  bool allowed = nondet_bool(), existing_reply = nondet_bool();
  int send_grant[] = {destination->id()};
  origin->grants_ = send_grant;
  origin->grants_count_ = allowed ? 1 : 0;
  int reply_grants[] = {existing_reply ? sender->id() : 24, 0};
  other->grants_ = reply_grants;
  other->grants_count_ = 1;
  destination->messages_.anchor_.next_ = nullptr;
  destination->messages_.tail_ = &destination->messages_.anchor_;
  bool mailbox_full = nondet_bool();
  destination->mailbox_count_ = mailbox_full ? PolicyQuotas::RECEIVER_FACTOR : 0;
  destination->mailbox_bytes_ = 0;
  sender->messages_.anchor_.next_ = nullptr;
  sender->messages_.tail_ = &sender->messages_.anchor_;
  sender->mailbox_count_ = destination->mailbox_count_;
  sender->mailbox_bytes_ = 0;
  bool sender_is_boot = nondet_bool(), receiver_is_boot = !sender_is_boot && nondet_bool();
  scheduler.boot_process_ = sender_is_boot ? sender : receiver_is_boot ? destination : nullptr;
  // The boot process can be in its unlocked destructor: no boot process, and
  // no default handling of the other processes' termination notices.
  bool boot_exiting = scheduler.boot_process_ == nullptr && nondet_bool();
  scheduler.boot_process_exiting_ = boot_exiting;
  // The scheduler's own notices (terminate_process, spawn) take the system
  // route directly; every process's message goes through send_message_from.
  bool from_scheduler = nondet_bool();
  bool system = from_scheduler || nondet_bool(), present = nondet_bool();
  requested = system ? -1 : destination->id();
  lookup_result = present ? destination : nullptr;
  int type = nondet_int();
  decodable = nondet_bool();
  exit_value = nondet_int();
  incoming = new SystemMessage(type, origin->id(), sender->id());
  CXXV_ASSUME(incoming != nullptr);
  uint8 payload[4] = {};
  incoming->data_ = payload;
  // No process can send the scheduler's life-cycle notices, on any route.
  bool forged = !from_scheduler && (type == SYSTEM_TERMINATED || type == SYSTEM_SPAWNED);
  bool denied = forged || (restricted && !allowed && !(present && (same || receiver_is_boot)));
  bool attempt = !system && !denied && present;
  bool needs_reply = !same && other_restricted && type == SYSTEM_RPC_REQUEST && !sender_is_boot;
  bool delivered = attempt && !mailbox_full && (!needs_reply || existing_reply || grant_room);
  bool reached_system = system && !forged;
  bool boot_delivery = reached_system && scheduler.boot_process_ != nullptr;
  bool queued = delivered || (boot_delivery && !mailbox_full);
  bool decode = reached_system && !boot_delivery && type == SYSTEM_TERMINATED && !boot_exiting;
  message_err_t expected = forged ? MESSAGE_PERMISSION_DENIED :
      system ? (boot_delivery && mailbox_full ? MESSAGE_QUOTA_EXCEEDED : MESSAGE_OK) : denied ? MESSAGE_PERMISSION_DENIED :
      !present ? MESSAGE_NO_SUCH_RECEIVER : delivered ? MESSAGE_OK : MESSAGE_QUOTA_EXCEEDED;
  message_err_t result;
  if (from_scheduler) {
    Locker locker(&scheduler_mutex);
    result = scheduler.send_system_message(locker, incoming);
    // Its callers delete a refused notice under the lock.
    if (result != MESSAGE_OK) cxxv_destroy(incoming);
  } else {
    result = scheduler.send_message_from(sender, requested, incoming);
  }
  CXXV_ASSERT(result == expected && !routing && !in_mailbox, "return the routing outcome after releasing both locks");
  CXXV_ASSERT(!forged || (lookups == 0 && mailbox_entries == 0 && decodes == 0 && destructions == 1),
              "refuse a forged life-cycle notice before routing it");
  CXXV_ASSERT(lookups == (!system && !forged) && mailbox_entries == (attempt || boot_delivery) && wakes == queued,
              "perform only authorized delivery and wake only a receiver that took the message");
  CXXV_ASSERT(destructions == !queued, "delete every unqueued message exactly once, including a consumed system notification");
  CXXV_ASSERT(decodes == decode && shutdowns == (decode && decodable),
              "handle termination only on the system route without a boot process, live or exiting, and only after successful decoding");
  CXXV_ASSERT(other->grants_count_ == 1 + (delivered && needs_reply && !existing_reply) &&
              other->may_send_to(sender->id()) == (existing_reply || (delivered && needs_reply)),
              "give the remote group a reply grant only for an admitted RPC request");
  CXXV_ASSERT(origin->grants_count_ == static_cast<word>(allowed) && origin->may_send_to(destination->id()) == allowed,
              "preserve the sending group's existing authority");
}

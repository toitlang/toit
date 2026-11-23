// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#include "process_group.cc"
#undef protected
#undef private

using namespace toit;

extern VM vm;
extern Scheduler scheduler;
VM* VM::current_ = &vm;
extern Mutex mailbox_mutex;
Mutex* OS::process_mutex_ = &mailbox_mutex;
static unsigned acquisitions;
static bool held;
static SystemMessage* released;
static Process* locked_receiver;
static MessageFIFO::Element* tail_at_unlock;
static word count_at_unlock, bytes_at_unlock, grants_at_unlock;

void Locker::enter() {
  CXXV_ASSERT(!held && mutex() == &mailbox_mutex, "enter the process mailbox mutex");
  held = true;
  ++acquisitions;
}

void Locker::leave() {
  CXXV_ASSERT(held && mutex() == &mailbox_mutex, "release the process mailbox mutex");
  tail_at_unlock = locked_receiver->messages_.tail_;
  count_at_unlock = locked_receiver->mailbox_count_;
  bytes_at_unlock = locked_receiver->mailbox_bytes_;
  grants_at_unlock = locked_receiver->group()->grants_count_;
  held = false;
}

void SystemMessage::free_data_and_externals() {
  CXXV_ASSERT(released == nullptr, "destroy a system message only once");
  released = this;
}

static bool fits(word used, word added, word limit, uword multiplier) {
  if (used < 0 || added < 0) return false;
  uword sum = static_cast<uword>(used) + static_cast<uword>(added);
  return sum <= static_cast<uword>(INTPTR_MAX) &&
         (limit <= 0 || sum / multiplier + (sum % multiplier != 0) <= static_cast<uword>(limit));
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "counter width");
  PrimitivePolicy policy;
  vm.scheduler_ = &scheduler;
  auto* group = new ProcessGroup(1, nullptr, nullptr, &policy);
  CXXV_ASSUME(group != nullptr);
  auto* process = new Process(static_cast<ProcessRunner*>(nullptr), group, nullptr);
  CXXV_ASSUME(process != nullptr);
  Process& receiver = *process;
  locked_receiver = process;
  receiver.messages_.anchor_.next_ = nullptr;
  receiver.messages_.tail_ = &receiver.messages_.anchor_;
  ObjectNotifyMessage prefix(nullptr);
  bool prefixed = nondet_bool();
  if (prefixed) receiver.messages_.append(&prefix);
  SystemMessage incoming(SYSTEM_RPC_REQUEST, 1, 2);
  auto* message = &incoming;
  word size = nondet_word();
  message->set_size(size);
  bool restricted = nondet_bool();
  word sender_count = nondet_word(), sender_bytes = nondet_word();
  if (restricted) message->set_restricted(sender_count, sender_bytes);
  word count = nondet_word(), bytes = nondet_word();
  word restricted_count = nondet_word(), restricted_bytes = nondet_word();
  receiver.mailbox_count_ = count;
  receiver.mailbox_bytes_ = bytes;
  receiver.restricted_count_ = restricted_count;
  receiver.restricted_bytes_ = restricted_bytes;
  word count_limit = nondet_word(), byte_limit = nondet_word();
  policy.quotas_.max_mailbox_messages = count_limit;
  policy.quotas_.max_mailbox_bytes = byte_limit;

  int capacity = nondet_int(), grants = nondet_int();
  CXXV_ASSUME(0 <= grants && grants <= capacity && capacity <= 2);
  policy.quotas_.max_send_grants = capacity;
  int grants_storage[2] = {13, 17};
  bool has_storage = grants != 0 || nondet_bool();
  group->grants_ = has_storage ? grants_storage : nullptr;
  group->grants_count_ = grants;
  int reply_to = nondet_int();
  bool had_grant = (grants >= 1 && reply_to == 13) || (grants == 2 && reply_to == 17);
  bool room = fits(count, 1, count_limit, PolicyQuotas::RECEIVER_FACTOR) &&
                  fits(bytes, size, byte_limit, PolicyQuotas::RECEIVER_FACTOR) &&
                  (!restricted || (fits(restricted_count, 1, sender_count, 1) &&
                                   fits(restricted_bytes, size, sender_bytes, 1)));
  bool admitted = receiver._append_message(message, reply_to);
  bool needs_grant = reply_to >= 0 && !had_grant;
  bool expected = room && (!needs_grant || (grants < capacity && group->grants_ != nullptr));
  CXXV_ASSERT(admitted == expected && !held && acquisitions == 1 && released == nullptr,
              "admit exactly when mailbox and requested reply grant permit, retaining ownership on rejection");
  CXXV_ASSERT(group->grants_count_ == grants + (admitted && needs_grant) &&
              (reply_to < 0 || group->may_send_to(reply_to) == (had_grant || admitted)),
              "publish a new reply grant only with a delivered request");
  CXXV_ASSERT((grants == 0 || group->grants_[0] == 13) && (grants < 2 || group->grants_[1] == 17),
              "preserve every existing grant");
  CXXV_ASSERT(room || group->grants_ == (has_storage ? grants_storage : nullptr),
              "mailbox rejection does not allocate grant storage");
  CXXV_ASSERT(receiver.mailbox_count_ == (admitted ? count + 1 : count) &&
              receiver.mailbox_bytes_ == (admitted ? bytes + size : bytes) &&
              receiver.restricted_count_ == (admitted && restricted ? restricted_count + 1 : restricted_count) &&
              receiver.restricted_bytes_ == (admitted && restricted ? restricted_bytes + size : restricted_bytes),
              "charge both counters exactly once for each applicable quota on admission");
  MessageFIFO::Element* incoming_link = message;
  MessageFIFO::Element* old_tail = prefixed ? static_cast<MessageFIFO::Element*>(&prefix) : &receiver.messages_.anchor_;
  CXXV_ASSERT(receiver.messages_.tail_ == (admitted ? incoming_link : old_tail) &&
              receiver.messages_.anchor_.next_ == (prefixed ? old_tail : admitted ? incoming_link : nullptr),
              "append only the accepted message at the tail, preserving the old head");
  CXXV_ASSERT(message->next_ == nullptr && prefix.next_ == (prefixed && admitted ? incoming_link : nullptr),
              "link only the prior tail to the accepted message");
  CXXV_ASSERT(tail_at_unlock == receiver.messages_.tail_ && count_at_unlock == receiver.mailbox_count_ &&
              bytes_at_unlock == receiver.mailbox_bytes_ && grants_at_unlock == group->grants_count_,
              "complete grant publication, mailbox charging and FIFO insertion before unlocking");
}

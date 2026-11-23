// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#undef protected
#undef private

using namespace toit;

extern Process receiver;
extern Mutex mailbox_mutex;
extern ObjectNotifier notifier;
extern MessageFIFO::Element* arbitrary_link();
Mutex* OS::process_mutex_ = &mailbox_mutex;
static bool held;
static unsigned acquisitions;
static unsigned destructions;
static Message* head_at_unlock;
static MessageFIFO::Element* tail_at_unlock;
static word count_at_unlock, bytes_at_unlock, restricted_count_at_unlock, restricted_bytes_at_unlock;

void Locker::enter() {
  CXXV_ASSERT(!held && mutex() == &mailbox_mutex, "acquire the process mailbox mutex");
  held = true;
  ++acquisitions;
}

void Locker::leave() {
  CXXV_ASSERT(held && mutex() == &mailbox_mutex, "release the process mailbox mutex");
  head_at_unlock = receiver.messages_.first();
  tail_at_unlock = receiver.messages_.tail_;
  count_at_unlock = receiver.mailbox_count_;
  bytes_at_unlock = receiver.mailbox_bytes_;
  restricted_count_at_unlock = receiver.restricted_count_;
  restricted_bytes_at_unlock = receiver.restricted_bytes_;
  held = false;
}

static void observe_destruction(Message* head) {
  CXXV_ASSERT(held && head->next_ == nullptr && receiver.messages_.first() != head,
              "unlink the head before destroying it under the mailbox lock");
  ++destructions;
}

void SystemMessage::free_data_and_externals() { observe_destruction(this); }

class ObservedNotify : public ObjectNotifyMessage {
 public:
  explicit ObservedNotify(ObjectNotifier* owner) : ObjectNotifyMessage(owner) {}
  ~ObservedNotify() override { observe_destruction(this); }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "counter width");
  receiver.messages_.anchor_.next_ = nullptr;
  receiver.messages_.tail_ = &receiver.messages_.anchor_;
  CXXV_ASSERT(!receiver.has_messages() && receiver.peek_message() == nullptr,
              "empty mailbox has no observable head");
  bool system = nondet_bool();
  bool restricted = system && nondet_bool();
  bool retained = !system && nondet_bool();
  word size = nondet_word();
  CXXV_ASSUME(size >= 0);
  Message* head;
  if (system) {
    auto* incoming = new SystemMessage(SYSTEM_RPC_REQUEST, 1, 2);
    CXXV_ASSUME(incoming != nullptr);
    incoming->set_size(size);
    if (restricted) incoming->set_restricted(1, size);
    head = incoming;
  } else {
    auto* incoming = new ObservedNotify(retained ? &notifier : nullptr);
    CXXV_ASSUME(incoming != nullptr);
    incoming->mark_queued();
    head = incoming;
  }
  receiver.messages_.append(head);
  ObjectNotifyMessage successor(nullptr);
  bool has_successor = nondet_bool();
  // Only the head is removed. Represent an arbitrary suffix by its first
  // outgoing link and cached tail. Removal needs no interior nodes.
  MessageFIFO::Element* suffix = nullptr;
  if (has_successor) {
    receiver.messages_.append(&successor);
    suffix = arbitrary_link();
    successor.next_ = suffix;
    if (suffix != nullptr) receiver.messages_.tail_ = arbitrary_link();
  }
  MessageFIFO::Element* original_tail = receiver.messages_.tail_;

  word count = nondet_word(), bytes = nondet_word();
  word restricted_count = nondet_word(), restricted_bytes = nondet_word();
  CXXV_ASSUME(count >= system && bytes >= (system ? size : 0));
  CXXV_ASSUME(restricted_count >= restricted && restricted_bytes >= (restricted ? size : 0));
  receiver.mailbox_count_ = count;
  receiver.mailbox_bytes_ = bytes;
  receiver.restricted_count_ = restricted_count;
  receiver.restricted_bytes_ = restricted_bytes;
  CXXV_ASSERT(receiver.has_messages() && receiver.peek_message() == head,
              "observe the same queued head before removal");
  receiver.remove_first_message();
  CXXV_ASSERT(!held && acquisitions == 5, "each observation and removal holds one lock");
  CXXV_ASSERT(destructions == (retained ? 0 : 1), "destroy exactly the released head");
  if (retained) {
    auto* notification = static_cast<ObjectNotifyMessage*>(head);
    CXXV_ASSERT(!notification->is_queued() && notification->object_notifier() == &notifier &&
                notification->next_ == nullptr, "return a detached notification to its owner");
  }
  CXXV_ASSERT(receiver.mailbox_count_ == count - system &&
              receiver.mailbox_bytes_ == bytes - (system ? size : 0) &&
              receiver.restricted_count_ == restricted_count - restricted &&
              receiver.restricted_bytes_ == restricted_bytes - (restricted ? size : 0),
              "refund the head's exact charges once");
  MessageFIFO::Element* expected_tail = has_successor
      ? original_tail : &receiver.messages_.anchor_;
  CXXV_ASSERT(head_at_unlock == (has_successor ? &successor : nullptr) &&
              tail_at_unlock == expected_tail && count_at_unlock == receiver.mailbox_count_ &&
              bytes_at_unlock == receiver.mailbox_bytes_ && restricted_count_at_unlock == receiver.restricted_count_ &&
              restricted_bytes_at_unlock == receiver.restricted_bytes_, "publish the new queue and counters before unlock");
  CXXV_ASSERT(receiver.messages_.tail_ == expected_tail && successor.next_ == suffix &&
              receiver.peek_message() == (has_successor ? &successor : nullptr) &&
              receiver.has_messages() == has_successor, "preserve the successor or restore the empty FIFO");
}

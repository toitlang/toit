// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#undef protected
#undef private

namespace toit {
#include "scheduler_notify.inc"
}

using namespace toit;
extern Scheduler scheduler;
extern Process receiver, ready_peer;
extern Mutex scheduling, mailbox;
extern ConditionVariable runnable;
extern ObjectNotifier monitor;
extern SystemMessage earlier;
Mutex* OS::process_mutex_ = &mailbox;

static bool scheduler_held, mailbox_held, receiving, signaled, woke_worker;
static unsigned mailbox_writes;
static ObjectNotifyMessage* notification;

void Locker::enter() {
  if (mutex() == &scheduling) {
    CXXV_ASSERT(!scheduler_held && !mailbox_held && !receiving, "lock the scheduler before publication");
    scheduler_held = true;
  } else {
    CXXV_ASSERT(mutex() == &mailbox && !mailbox_held && scheduler_held == !receiving,
                "take the mailbox mutex under the scheduler lock on delivery and alone on receive");
    mailbox_held = true;
    if (!receiving) ++mailbox_writes;
  }
}
void Locker::leave() {
  if (mutex() == &scheduling) {
    CXXV_ASSERT(scheduler_held && !mailbox_held, "finish publication before unlocking the scheduler");
    scheduler_held = false;
  } else {
    CXXV_ASSERT(mutex() == &mailbox && mailbox_held, "release the mailbox mutex");
    mailbox_held = false;
  }
}
void OS::signal(ConditionVariable* cv) {
  CXXV_ASSERT(scheduler_held && !mailbox_held && !signaled && cv == &runnable &&
              scheduler.ready_count_ == 1 && notification->is_queued(),
              "signal the first ready entry after mailbox publication");
  signaled = true;
}
void Scheduler::wake_worker_for_ready_process(Locker& lock, uint8 priority) {
  CXXV_ASSERT(scheduler_held && !mailbox_held && lock.mutex() == &scheduling && !woke_worker &&
              priority == receiver.priority() && ready_queue(priority).last() == &receiver &&
              receiver.state() == Process::SCHEDULED && notification->is_queued(),
              "notify workers after publishing the receiver at its applied priority");
  woke_worker = true;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  scheduler.mutex_ = &scheduling;
  scheduler.has_processes_ = &runnable;
  monitor.process_ = &receiver;
  notification = new ObjectNotifyMessage(&monitor);
  monitor.set_message(notification);
  new (&receiver.messages_) MessageFIFO();
  bool with_earlier = nondet_bool();
  if (with_earlier) receiver.messages_.append(&earlier);
  bool already_queued = nondet_bool();
  if (already_queued) {
    notification->mark_queued();
    receiver.messages_.append(notification);
  }

  unsigned state = nondet_uchar();
  CXXV_ASSUME(state <= Process::SUSPENDED_AWAITING_GC);
  auto initial = static_cast<Process::State>(state);
  receiver.set_state(initial);
  uint8 old_priority = nondet_uchar();
  uint8 target_priority = nondet_uchar();
  receiver.priority_ = old_priority;
  receiver.set_target_priority(target_priority);
  // Use the actual ready bucket for the priority the receiver occupies or
  // will acquire. A peer in that bucket may already precede it.
  using ReadyLink = ProcessListFromScheduler::Element;
  new (static_cast<ReadyLink*>(&receiver)) ReadyLink();
  new (static_cast<ReadyLink*>(&ready_peer)) ReadyLink();
  auto& queue = scheduler.ready_queue(initial == Process::IDLE ? target_priority : old_priority);
  new (&queue) ProcessListFromScheduler();
  bool with_peer = nondet_bool();
  if (with_peer) queue.append(&ready_peer);
  bool scheduled = initial == Process::SCHEDULED;
  if (scheduled) queue.append(&receiver);
  scheduler.ready_count_ = with_peer + scheduled;

  word messages = nondet_word(), bytes = nondet_word();
  word restricted = nondet_word(), restricted_bytes = nondet_word();
  receiver.mailbox_count_ = messages;
  receiver.mailbox_bytes_ = bytes;
  receiver.restricted_count_ = restricted;
  receiver.restricted_bytes_ = restricted_bytes;

  scheduler.send_notify_message(&monitor);
  bool live = initial != Process::TERMINATING;
  bool linked = already_queued || live;
  CXXV_ASSERT(notification->is_queued() == linked &&
              receiver.messages_.first() == (with_earlier ? static_cast<Message*>(&earlier) : linked ? notification : nullptr) &&
              receiver.messages_.last() == (linked ? static_cast<Message*>(notification) : with_earlier ? &earlier : nullptr),
              "publish at the mailbox tail and leave a terminating receiver's mailbox intact");

  // If the receiver consumes the notification between events, the same
  // live message becomes reusable. Otherwise the next delivery coalesces.
  if (live && !with_earlier && nondet_bool()) {
    receiving = true;
    receiver.remove_first_message();
    receiving = false;
    CXXV_ASSERT(receiver.messages_.is_empty() && !notification->is_queued() &&
                notification->object_notifier() == &monitor, "dequeue releases the live message for reuse");
  }
  scheduler.send_notify_message(&monitor);
  auto* next = static_cast<MessageFIFO::Element*>(notification)->next_;
  CXXV_ASSERT(notification->is_queued() == linked && notification->object_notifier() == &monitor &&
              (with_earlier ? (receiver.messages_.first() == &earlier &&
                 static_cast<MessageFIFO::Element*>(&earlier)->next_ == (linked ? static_cast<MessageFIFO::Element*>(notification) : nullptr)) :
                 receiver.messages_.first() == (linked ? notification : nullptr)) &&
              next == nullptr && receiver.messages_.last() ==
                 (linked ? static_cast<Message*>(notification) : with_earlier ? &earlier : nullptr),
              "retain FIFO order and exactly one entry for a live monitor after repeated sends");

  bool newly_ready = initial == Process::IDLE;
  auto expected_state = newly_ready ? Process::SCHEDULED :
                        initial == Process::SUSPENDED_IDLE ? Process::SUSPENDED_SCHEDULED : initial;
  bool on_queue = scheduled || newly_ready;
  CXXV_ASSERT(receiver.state() == expected_state && receiver.priority() == (newly_ready ? target_priority : old_priority) &&
              queue.first() == (with_peer ? &ready_peer : on_queue ? &receiver : nullptr) &&
              queue.last() == (on_queue ? &receiver : with_peer ? &ready_peer : nullptr) &&
              (!with_peer || static_cast<ReadyLink*>(&ready_peer)->next_ == (on_queue ? static_cast<ReadyLink*>(&receiver) : nullptr)) &&
              (!on_queue || static_cast<ReadyLink*>(&receiver)->next_ == nullptr) &&
              scheduler.ready_count_ == with_peer + on_queue && woke_worker == newly_ready &&
              signaled == (newly_ready && !with_peer), "make only an idle receiver newly runnable");
  CXXV_ASSERT(!scheduler_held && !mailbox_held && mailbox_writes == 2u * live &&
              receiver.mailbox_count_ == messages && receiver.mailbox_bytes_ == bytes &&
              receiver.restricted_count_ == restricted && receiver.restricted_bytes_ == restricted_bytes,
              "release both locks and preserve all mailbox quota charges");
}

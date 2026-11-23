// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include <limits.h>
#define private public
#define protected public
#include "process.cc"
#undef protected
#undef private

namespace toit {
static ProcessListFromScheduler& selected_ready_queue(uint8);
#include "scheduler_gc_ownership.inc"
}

using namespace toit;
extern Scheduler scheduler;
extern Process target, peer;
extern Program program;
extern Mutex mutex;
extern ConditionVariable condition;
static ProcessListFromScheduler claimed, ready;
static bool held, released, signaled, notified;
static int other_ready;
static uint8 requested_priority;

void Locker::enter() {
  CXXV_ASSERT(!held && this->mutex() == &::mutex, "serialize the transition under the scheduler lock");
  held = true;
}
void Locker::leave() {
  CXXV_ASSERT(held, "release the scheduler lock after the transition");
  held = false;
}

ProcessListFromScheduler& toit::selected_ready_queue(uint8 priority) {
  CXXV_ASSERT(held && released && priority == requested_priority && target.priority() == priority &&
              target.state() == Process::SCHEDULED && claimed.first() != &target &&
              !static_cast<ProcessListFromScheduler::Element*>(&target)->next_ && ready.is_empty(),
              "free the target's collector link before selecting its ready bucket");
  return ready;
}

void OS::signal(ConditionVariable* cv) {
  CXXV_ASSERT(held && !signaled && cv == &condition && other_ready == 0 && scheduler.ready_count_ == 1 &&
              released && ready.first() == &target, "signal only on the transition from an empty ready set");
  signaled = true;
}

void Scheduler::wake_worker_for_ready_process(Locker& lock, uint8 priority) {
  CXXV_ASSERT(held && lock.mutex() == &mutex && !notified && released && priority == requested_priority &&
              target.priority() == priority && target.state() == Process::SCHEDULED &&
              claimed.first() != &target && ready.first() == &target &&
              scheduler.ready_count_ == other_ready + 1, "notify workers after updating the ready count");
  notified = true;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Locker lock(&mutex);
  bool barrier_waiter = nondet_bool();
  bool pending = !barrier_waiter && nondet_bool();
  bool with_peer = nondet_bool();
  uint8 old_priority = nondet_uchar();
  requested_priority = nondet_uchar();
  target.program_ = &program;
  target.set_idle_since_gc(false);
  target.priority_ = old_priority;
  target.set_target_priority(requested_priority);
  target.set_state(barrier_waiter ? Process::SUSPENDED_AWAITING_GC :
                   pending ? Process::SUSPENDED_SCHEDULED : Process::SUSPENDED_IDLE);
  auto* group_link = static_cast<ProcessListFromProcessGroup::Element*>(&target);
  auto* next_member = group_link->next_;
  claimed.append(&target);
  if (with_peer) {
    peer.set_state(Process::SUSPENDED_AWAITING_GC);
    claimed.append(&peer);
  }
  auto* link = static_cast<ProcessListFromScheduler::Element*>(&target);
  auto* next_target = link->next_;
  other_ready = nondet_int();
  CXXV_ASSUME(0 <= other_ready && other_ready < INT_MAX);
  scheduler.ready_count_ = other_ready;
  scheduler.has_processes_ = &condition;

  // One locked step from an arbitrary pending-wakeup and priority state.
  // Each non-release case must preserve the input ownership invariant.
  unsigned event = nondet_uchar();
  CXXV_ASSUME(event <= 3);
  if (event == 0) {
    scheduler.process_ready(lock, &target);
    if (!barrier_waiter) pending = true;
  } else if (event == 1) {
    requested_priority = nondet_uchar();
    scheduler.update_priority(lock, &target, requested_priority);
  } else if (event == 2) {
    bool peer_owner = !barrier_waiter && nondet_bool();
    CXXV_ASSERT(!scheduler.claim_gc_target(lock, &target, peer_owner),
                "a competing collection leaves the target in its original collector queue");
  } else {
    released = true;
    scheduler.resume_gc_targets(lock, &claimed);
  }

  bool runnable = released && pending;
  auto state = barrier_waiter ? Process::SUSPENDED_AWAITING_GC :
               released ? (pending ? Process::SCHEDULED : Process::IDLE) :
               pending ? Process::SUSPENDED_SCHEDULED : Process::SUSPENDED_IDLE;
  CXXV_ASSERT(target.state() == state && target.target_priority_ == requested_priority &&
              target.priority() == (runnable ? requested_priority : old_priority),
              "retain the pending wake and requested priority until ordinary resumption");
  CXXV_ASSERT(claimed.first() == (released ? nullptr : &target) &&
              link->next_ == (released ? nullptr : next_target) && group_link->next_ == next_member,
              "keep collector and group membership links intact until collector removal");
  CXXV_ASSERT(notified == runnable && signaled == (runnable && other_ready == 0) &&
              ready.first() == (runnable ? &target : nullptr) && scheduler.ready_count_ == other_ready + runnable,
              "publish exactly one ready entry for an ordinary suspension with a pending wake");
}

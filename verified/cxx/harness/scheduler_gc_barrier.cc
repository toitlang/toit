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
#include "scheduler_gc_barrier.inc"
}

using namespace toit;
extern Scheduler scheduler;
extern Process target;
extern Program program;
extern Mutex mutex;
extern ConditionVariable condition;
static bool spurious;
static int wakes, initial_count;

extern Process before, after;

static ProcessListFromScheduler ready;
static uint8 original_priority;
ProcessListFromScheduler& toit::selected_ready_queue(uint8 priority) {
  CXXV_ASSERT(priority == original_priority && target.state() == Process::SUSPENDED_SCHEDULED,
              "remove a suspended scheduled target from its original priority bucket");
  return ready;
}

void Locker::enter() {}
void Locker::leave() {}

void OS::wait(ConditionVariable* cv) {
  CXXV_ASSERT(scheduler.gc_waiting_for_preemption_ == initial_count && cv == &condition && scheduler.gc_cross_processes_ &&
              target.state() == Process::SUSPENDED_AWAITING_GC,
              "wait with the target suspended until the collector releases the barrier");
  if (++wakes == 2 || !spurious) scheduler.gc_cross_processes_ = false;
}

int main() {
  Locker locker(&mutex);
  bool external = nondet_bool();
  bool idle_since = nondet_bool();
  bool cross_owner = nondet_bool();
  target.program_ = external ? nullptr : &program;
  target.set_idle_since_gc(idle_since);
  int state = nondet_int();
  CXXV_ASSUME(state >= Process::IDLE && state <= Process::SUSPENDED_AWAITING_GC);
  target.set_state(static_cast<Process::State>(state));
  original_priority = nondet_uchar();
  target.priority_ = original_priority;
  bool scheduled = state == Process::SCHEDULED;
  bool has_before = nondet_bool();
  bool has_after = nondet_bool();
  if (has_before) ready.append(&before);
  if (scheduled) ready.append(&target);
  if (has_after) ready.append(&after);
  int other_buckets = nondet_int();
  CXXV_ASSUME(0 <= other_buckets && other_buckets <= INT_MAX - 3);
  int other_ready = other_buckets + has_before + has_after;
  scheduler.ready_count_ = other_ready + scheduled;
  auto* membership = static_cast<ProcessListFromProcessGroup::Element*>(&target);
  auto* group_next = membership->next_;
  bool claimed = scheduler.claim_gc_target(locker, &target, cross_owner);
  bool ordinary = state == Process::IDLE || state == Process::SCHEDULED;
  bool expected = !external && !idle_since &&
                  (ordinary || (cross_owner && state == Process::SUSPENDED_AWAITING_GC));
  CXXV_ASSERT(claimed == expected, "select exactly eligible targets belonging to this collector");
  auto expected_state = claimed && ordinary
      ? (state == Process::IDLE ? Process::SUSPENDED_IDLE : Process::SUSPENDED_SCHEDULED)
      : static_cast<Process::State>(state);
  bool still_ready = scheduled && !claimed;
  CXXV_ASSERT(target.state() == expected_state &&
              scheduler.ready_count_ == other_ready + still_ready && membership->next_ == group_next,
              "claim removes exactly one scheduled process and preserves group membership");
  auto* link = static_cast<ProcessListFromScheduler::Element*>(&target);
  CXXV_ASSERT(!(claimed && scheduled) || !link->next_, "the removed target has a free scheduler link for the collector");
  // Check the resulting order, including a middle removal and a repaired tail.
  CXXV_ASSERT(ready.last() == (has_after ? &after : still_ready ? &target : has_before ? &before : nullptr),
              "retain the correct tail when claiming any position");
  if (has_before) CXXV_ASSERT(ready.remove_first() == &before, "retain the predecessor");
  if (still_ready) CXXV_ASSERT(ready.remove_first() == &target, "retain a scheduled target when its claim is rejected");
  if (has_after) CXXV_ASSERT(ready.remove_first() == &after, "retain the successor");
  CXXV_ASSERT(ready.is_empty(), "no unexpected entry remains");
  if (claimed) {
    // A second collector may own the cross-process barrier only if the
    // first one does not. Both can run ordinary idle collections.
    bool second_owner = !cross_owner && nondet_bool();
    CXXV_ASSERT(!scheduler.claim_gc_target(locker, &target, second_owner),
                "overlapping collectors cannot claim the same target");
  }

  bool active = nondet_bool();
  scheduler.gc_cross_processes_ = active;
  scheduler.gc_condition_ = &condition;
  initial_count = nondet_int();
  CXXV_ASSUME(initial_count >= 0);
  scheduler.gc_waiting_for_preemption_ = initial_count;
  target.set_scheduler_thread(nullptr);
  target.set_state(Process::RUNNING);
  spurious = nondet_bool();
  auto next = nondet_bool() ? Process::IDLE : Process::RUNNING;
  scheduler.wait_for_any_gc_to_complete(locker, &target, next);
  CXXV_ASSERT(!scheduler.gc_cross_processes_ && target.state() == next && scheduler.gc_waiting_for_preemption_ == initial_count &&
              wakes == (active ? (spurious ? 2 : 1) : 0),
              "teardown or dispatch resumes only after the active barrier clears");
}

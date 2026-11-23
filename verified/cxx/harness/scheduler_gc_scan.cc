// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#undef protected
#undef private
#include "hw_perf.h"

namespace toit {
static ProcessListFromScheduler& selected_ready_queue(uint8);
#include "scheduler_gc_scan.inc"
}

using namespace toit;
extern Scheduler scheduler;
extern Process target;
extern ProcessGroup group;
extern SchedulerThread worker;
extern Program program;
extern Mutex mutex;
extern ConditionVariable condition;
static bool held, hard, other_owner, waiter, scanned, released;
static bool has_worker, timed_out, late_arrival, waited, preempted;

static void arrive_at_barrier() {
  CXXV_ASSERT(held, "serialize acknowledgment and suspension under the scheduler lock");
  if (has_worker) worker.interpreter()->process_ = nullptr;
  target.set_scheduler_thread(nullptr);
  if (has_worker) scheduler.acknowledge_gc_preemption(&worker);
  target.set_state(Process::SUSPENDED_AWAITING_GC);
}

void Interpreter::preempt() {
  CXXV_ASSERT(held && hard && !other_owner && this == worker.interpreter() &&
              target.signals() == Process::PREEMPT, "request preemption from the active interpreter under lock");
  preempted = true;
}

bool OS::wait_us(ConditionVariable* cv, int64 remaining) {
  CXXV_ASSERT(held && !waited && preempted && cv == &condition && remaining > 0 &&
              scheduler.gc_waiting_for_preemption_ == 1, "wait for the running worker or the preemption deadline");
  waited = true;
  if (timed_out) return false;
  arrive_at_barrier();
  return true;
}

int64 OS::get_monotonic_time() { return 1000; }
void Locker::enter() {
  CXXV_ASSERT(!held && mutex() == &::mutex, "acquire the scheduler lock");
  held = true;
}
void Locker::leave() {
  CXXV_ASSERT(held, "release the scheduler lock");
  held = false;
  // A worker can enter the waiter state after the owner raises its barrier.
  if (waiter && (!has_worker || late_arrival) && scheduler.gc_cross_processes_ && target.state() == Process::RUNNING) {
    held = true;  // An arriving worker acquires the lock the collector just released.
    arrive_at_barrier();
    held = false;
  }
}

static bool initially_scheduled, wake_during_scan, enqueued;
extern ConditionVariable ready_condition;
static ProcessListFromScheduler ready;

ProcessListFromScheduler& toit::selected_ready_queue(uint8 priority) {
  CXXV_ASSERT(held && priority == Process::PRIORITY_NORMAL, "use the fixture's active priority bucket under lock");
  return ready;
}

void OS::signal(ConditionVariable* cv) {
  CXXV_ASSERT(held && scanned && !waiter && (initially_scheduled || wake_during_scan) && !enqueued &&
              cv == &ready_condition && target.state() == Process::SCHEDULED &&
              scheduler.ready_count_ == 1 && ready.first() == &target,
              "wake a scheduler worker only after the scan and ready-queue insertion");
  enqueued = true;
}

void Scheduler::wake_worker_for_ready_process(Locker& lock, uint8 priority) {
  CXXV_ASSERT(held && lock.mutex() == &mutex && enqueued && priority == target.priority(),
              "notify workers only after publishing the ready process at its active priority");
}

GcType ObjectHeap::gc(bool try_hard) {
  CXXV_ASSERT(this == target.object_heap() && !held && !scanned && !released && try_hard == hard,
              "scan the claimed heap once outside the lock before releasing the barrier");
  if (waiter) {
    CXXV_ASSERT(hard && !other_owner && scheduler.gc_cross_processes_ &&
                target.state() == Process::SUSPENDED_AWAITING_GC, "only the barrier owner scans a waiter");
  } else {
    CXXV_ASSERT(target.state() == (initially_scheduled ? Process::SUSPENDED_SCHEDULED : Process::SUSPENDED_IDLE) &&
                scheduler.ready_count_ == 0 && ready.is_empty(),
                "an ordinary target is suspended and absent from the ready queue during its scan");
  }
  if (wake_during_scan) {
    Locker lock(&mutex);
    scheduler.process_ready(lock, &target);
    scheduler.process_ready(lock, &target);
    CXXV_ASSERT(!enqueued && scheduler.ready_count_ == 0 &&
                target.state() == (waiter ? Process::SUSPENDED_AWAITING_GC : Process::SUSPENDED_SCHEDULED),
                "repeated wakeups leave the claimed process off the ready queue during the scan");
  }
  scanned = true;
  return nondet_bool() ? NEW_SPACE_GC : FULL_GC;
}

void OS::signal_all(ConditionVariable* cv) {
  if (scheduler.gc_cross_processes_) {
    CXXV_ASSERT(held && cv == &condition && preempted && waited && !timed_out && !released &&
                scheduler.gc_waiting_for_preemption_ == 0 && !worker.gc_preemption_requested_,
                "the returning worker wakes the preemption wait after clearing its mark");
    return;
  }
  CXXV_ASSERT(held && cv == &condition && !scheduler.gc_cross_processes_ && !released &&
              hard && !other_owner && scanned == (!has_worker || !timed_out || late_arrival) &&
              target.state() == (!waiter ? ((initially_scheduled || wake_during_scan) ? Process::SCHEDULED : Process::IDLE) : scanned ? Process::SUSPENDED_AWAITING_GC : Process::RUNNING),
              "the owner wakes workers after heap scanning and ordinary resumption");
  released = true;
}

int main() {
  new (&scheduler.groups_) ProcessGroupList();
  new (&group.processes_) ProcessListFromProcessGroup();
  new (&scheduler.threads_) SchedulerThreadList();
  scheduler.groups_.append(&group);
  group.processes_.prepend(&target);
  hard = nondet_bool();
  other_owner = nondet_bool();
  waiter = nondet_bool();
  has_worker = waiter && !other_owner && nondet_bool();
  timed_out = nondet_bool();
  late_arrival = nondet_bool();
  wake_during_scan = nondet_bool();
  target.priority_ = target.target_priority_ = Process::PRIORITY_NORMAL;
  initially_scheduled = !waiter && nondet_bool();
  if (initially_scheduled) ready.append(&target);
  scheduler.ready_count_ = initially_scheduled;
  scheduler.has_processes_ = &ready_condition;
  target.signals_ = 0;
  target.set_scheduler_thread(has_worker ? &worker : nullptr);
  if (has_worker) {
    worker.interpreter()->process_ = &target;
    scheduler.threads_.prepend(&worker);
  }
  scheduler.mutex_ = &mutex;
  scheduler.gc_condition_ = &condition;
  scheduler.gc_cross_processes_ = other_owner;
  target.program_ = &program;
  target.set_idle_since_gc(false);
  target.set_state(!waiter ? (initially_scheduled ? Process::SCHEDULED : Process::IDLE) : other_owner ? Process::SUSPENDED_AWAITING_GC : Process::RUNNING);
  scheduler.gc(nullptr, true, hard);
  bool owned = hard && !other_owner;
  CXXV_ASSERT(!held && released == owned && scheduler.gc_cross_processes_ == other_owner,
              "a collector leaves another collector's barrier intact");
  CXXV_ASSERT(preempted == (owned && has_worker) && waited == preempted,
              "only the cross-process collector requests and waits for preemption");
  CXXV_ASSERT(scanned == ((owned && (!has_worker || !timed_out || late_arrival)) || (!hard && !waiter)),
              "scan each eligible target and skip a peer collector's waiter");
  bool runnable = initially_scheduled || (!waiter && scanned && wake_during_scan);
  CXXV_ASSERT(enqueued == (runnable && scanned) && scheduler.ready_count_ == runnable &&
              ready.first() == (runnable ? &target : nullptr) &&
              (waiter || target.state() == (runnable ? Process::SCHEDULED : Process::IDLE)),
              "resume an ordinary target with exactly one queue entry when a wakeup arrived");
}

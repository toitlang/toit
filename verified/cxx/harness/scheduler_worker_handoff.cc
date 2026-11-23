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
static void handoff_finished();
static uint8* read_preemption_header(Interpreter*);
#include "scheduler_worker_handoff.inc"
}

using namespace toit;
extern Scheduler scheduler;
extern SchedulerThread worker, other_worker;
extern Process other_active;
static Process* subject;
extern VM vm;
VM* VM::current_ = &vm;
int Scheduler::next_process_id() { return 1; }
extern Mutex mutex, mailbox;
extern ConditionVariable condition, runnable, threads_left;
extern Process next_ready;
extern Program program;
static bool starting, with_peer, notified_peer, halted, read_header, profiling;
static int profiler_balance;
static unsigned profiler_starts;
extern Profiler profiler;
static uint8 prior_header, current_header;
static unsigned watchdogs;
Mutex* OS::process_mutex_ = &mailbox;
extern SystemMessage message;
static bool held, external, finished, executed, mailbox_held;
static bool initial_barrier, peer_gc, kill_during, messaged, ready, terminated;
static uint8 initial_signals, kill_code;
static int64 result_value;
static unsigned waits, unlocks, clock_reads, preemptions, acknowledgments;
static bool unrelated, peer_returned, finish_gc_during_run, in_collector, deadline_expired, owner_released;
static unsigned scans;
static Locker* dispatch_lock;
static int64 start_time, stop_time;
static Interpreter::Result::State outcome;

uint8* toit::read_preemption_header(Interpreter* interpreter) {
  CXXV_ASSERT(held && executed && !external && !read_header && outcome == Interpreter::Result::PREEMPTED &&
              interpreter == worker.interpreter() && interpreter->process() == subject,
              "read preemption metadata only from an execution that actually returned preempted");
  read_header = true;
  return interpreter->preemption_method_header_bcp();
}

void Scheduler::notify_profiler(Locker& lock, int change) {
  CXXV_ASSERT(held && profiling && !external && &lock == dispatch_lock && subject->scheduler_thread() == &worker &&
              !worker.interpreter()->process() && change == (profiler_balance == 0 ? 1 : -1),
              "balance profiler activity around the interpreted dispatch under the scheduler lock");
  profiler_balance += change;
  if (change > 0) ++profiler_starts;
}

static bool unbound() {
  return !subject->scheduler_thread() && !worker.interpreter()->process();
}

void Locker::enter() {
  if (this->mutex() == &mailbox) {
    CXXV_ASSERT(held && !mailbox_held && unbound(), "read the yielded mailbox after releasing worker ownership");
    mailbox_held = true;
    return;
  }
  CXXV_ASSERT(this->mutex() == &::mutex && !held, "serialize worker ownership on the scheduler mutex");
  held = true;
  if (starting && !dispatch_lock) dispatch_lock = this;
}

void Locker::leave() {
  if (this->mutex() == &mailbox) {
    CXXV_ASSERT(held && mailbox_held, "finish the mailbox check under the scheduler lock");
    mailbox_held = false;
    return;
  }
  CXXV_ASSERT(held && !mailbox_held, "unlock the held scheduler mutex");
  if (this == dispatch_lock && !finished) {
    CXXV_ASSERT(!scheduler.gc_cross_processes_ && subject->state() == Process::RUNNING &&
                subject->scheduler_thread() == &worker && worker.interpreter()->process() == (external ? nullptr : subject) &&
                subject->run_timestamp_ == start_time && subject->idle_since_gc() == external,
                "publish the running state, ownership and timestamp before unlocking for execution");
    ++unlocks;
  }
  held = false;
}

int64 OS::get_monotonic_time() {
  if (in_collector) return 1000;
  CXXV_ASSERT(held && clock_reads < 2, "sample run accounting under the scheduler lock");
  return clock_reads++ == 0 ? start_time : stop_time;
}

void OS::signal_all(ConditionVariable* cv) {
  if (in_collector) {
    CXXV_ASSERT(held && cv == &condition && !scheduler.gc_cross_processes_ && !owner_released &&
                subject->state() == Process::RUNNING && subject->scheduler_thread() == &worker &&
                worker.gc_preemption_requested_ == !external && scheduler.gc_waiting_for_preemption_ == 0,
                "the collector releases its barrier with the running subject still bound");
    owner_released = true;
    return;
  }
  if (!clock_reads) {
    CXXV_ASSERT(held && cv == &condition && scheduler.gc_cross_processes_ && unrelated && !peer_returned &&
                unbound() && !other_worker.gc_preemption_requested_ && scheduler.gc_waiting_for_preemption_ == 0,
                "only the other marked worker completes the initial preemption wait");
    peer_returned = true;
    return;
  }
  CXXV_ASSERT(held && cv == &condition && scheduler.gc_cross_processes_ && unbound() &&
              executed && peer_gc && !external && subject->state() == Process::RUNNING &&
              !worker.gc_preemption_requested_ && scheduler.gc_waiting_for_preemption_ == 0,
              "acknowledge exactly the marked worker after retiring its interpreter binding");
  ++acknowledgments;
}

// An active or barrier-waiting dispatch never enters ordinary suspension.
void Scheduler::gc_suspend_process(Locker&, Process*) {
  CXXV_ASSERT(false, "the collector cannot take ownership of this dispatch through ordinary suspension");
}

void Scheduler::gc_resume_process(Locker&, Process*) {
  CXXV_ASSERT(false, "the collector cannot resume a process owned by this worker");
}

bool OS::wait_us(ConditionVariable* cv, int64 remaining) {
  CXXV_ASSERT(in_collector && held && !external && !deadline_expired && cv == &condition &&
              remaining > 0 && scheduler.gc_waiting_for_preemption_ == 1 && worker.gc_preemption_requested_,
              "the collector deadline expires before the active interpreter returns");
  deadline_expired = true;
  return false;
}

GcType ObjectHeap::gc(bool hard) {
  CXXV_ASSERT(!held && hard && this == subject->object_heap() && !in_collector &&
              scheduler.gc_cross_processes_ && subject->state() == Process::SUSPENDED_AWAITING_GC &&
              unbound() && subject->run_timestamp_ < 0,
              "collector enters the subject heap only after the worker has detached and published suspension");
  ++scans;
  return nondet_bool() ? NEW_SPACE_GC : FULL_GC;
}

void OS::wait(ConditionVariable* cv) {
  CXXV_ASSERT(held && cv == &condition && unbound() && subject->state() == Process::SUSPENDED_AWAITING_GC &&
              subject->run_timestamp_ < 0, "GC may scan the waiting process with no active interpreter or run timestamp");
  CXXV_ASSERT(scheduler.gc_waiting_for_preemption_ == (clock_reads == 0 ? unrelated : 0),
              "entry wait preserves preemption requests for unrelated workers");
  if (!clock_reads && unrelated) {
    other_worker.interpreter()->deactivate();
    other_active.set_scheduler_thread(nullptr);
    scheduler.acknowledge_gc_preemption(&other_worker);
    CXXV_ASSERT(peer_returned, "the initial barrier waits for the signaled peer to retire");
  }
  // A condition wait releases the scheduler mutex until the collector is done.
  held = false;
  ProcessListFromScheduler targets;
  bool eligible = !external && !subject->idle_since_gc();
  {
    Locker collector(&mutex);
    scheduler.select_gc_targets(collector, &targets, true);
    CXXV_ASSERT(targets.first() == (eligible ? subject : nullptr),
                "the collector claims the eligible dispatch waiter through its process group");
  }
  unsigned prior_scans = scans;
  auto visited = scheduler.scan_gc_targets(targets, true);
  CXXV_ASSERT(visited == eligible && scans == prior_scans + eligible,
              "scan exactly the selected waiter before allowing its dispatch to continue");
  {
    Locker collector(&mutex);
    scheduler.resume_gc_targets(collector, &targets);
    CXXV_ASSERT(targets.is_empty() && subject->state() == Process::SUSPENDED_AWAITING_GC,
                "release the target list while leaving the waiting worker in control of its next state");
  }
  held = true;
  ++waits;
  scheduler.gc_cross_processes_ = false;
}

void Interpreter::preempt() {
  if (this == other_worker.interpreter()) {
    CXXV_ASSERT(held && initial_barrier && unrelated && process() == &other_active &&
                other_active.scheduler_thread() == &other_worker && (other_active.signals() & Process::PREEMPT),
                "signal the other worker whose interpreter is running");
    return;
  }
  CXXV_ASSERT(held && this == worker.interpreter() && process() == (external ? nullptr : subject) &&
              subject->scheduler_thread() == &worker && (subject->signals() & (Process::PREEMPT | Process::KILL)),
              "signal delivery reaches the assigned worker while the binding is stable");
  ++preemptions;
}

static Interpreter::Result execute() {
  CXXV_ASSERT(!held && !executed && unlocks == 1 && initial_signals == 0 &&
              waits == initial_barrier, "execute once after entry GC completes and only with no pending signal");
  executed = true;
  if (peer_gc && finish_gc_during_run) {
    in_collector = true;
    scheduler.gc(nullptr, true, true);
    in_collector = false;
    CXXV_ASSERT(owner_released && deadline_expired == !external && !held &&
                worker.interpreter()->process() == (external ? nullptr : subject),
                "a full peer collection skips this still-executing dispatch");
  }
  if (peer_gc || kill_during) {
    Locker peer_lock(&mutex);
    if (peer_gc && !finish_gc_during_run) {
      scheduler.gc_cross_processes_ = true;
      scheduler.gc_waiting_for_preemption_ = scheduler.request_gc_preemption(nullptr);
      CXXV_ASSERT(scheduler.gc_waiting_for_preemption_ == !external,
                  "a peer collector sees exactly the active interpreter binding");
    }
    if (kill_during) subject->kill_for_policy(kill_code);
  }
  return Interpreter::Result(outcome, result_value);
}

Interpreter::Result Interpreter::run() {
  CXXV_ASSERT(!external && this == worker.interpreter(), "dispatch the bound interpreter");
  auto result = execute();
  preemption_method_header_bcp_ = result.state() == Result::PREEMPTED && nondet_bool() ? &current_header : nullptr;
  return result;
}

class Runner : public ProcessRunner {
 public:
  Interpreter::Result run() override {
    CXXV_ASSERT(external && !worker.interpreter()->process(), "external execution leaves the interpreter unbound");
    return execute();
  }
  void set_process(Process*) override {}
};

void Scheduler::terminate_execution(Locker& lock, ExitState exit) {
  bool sleep = outcome == Interpreter::Result::DEEP_SLEEP;
  CXXV_ASSERT(held && &lock == dispatch_lock && external && executed && unbound() && !halted &&
              (sleep || outcome == Interpreter::Result::RESET) &&
              exit.reason == (sleep ? EXIT_DEEP_SLEEP : EXIT_RESET) && exit.value == (sleep ? result_value : 0),
              "only the trusted runner may request the modeled device halt after releasing the worker");
  halted = true;
}

void OS::feed_watchdog() {
  CXXV_ASSERT(held && !finished && !watchdogs && unbound(), "one worker takes the dispatch lock before selecting work");
  ++watchdogs;
}

void OS::signal(ConditionVariable* cv) {
  CXXV_ASSERT(held, "notify scheduler workers with the dispatch lock held");
  if (!finished) {
    CXXV_ASSERT(cv == &runnable && with_peer && !notified_peer && scheduler.ready_count_ == 1 &&
                scheduler.ready_queue(Process::PRIORITY_CRITICAL).first() == &next_ready && unbound(),
                "notify a peer only after detaching the selected process");
    notified_peer = true;
  }
}

void toit::handoff_finished() {
  CXXV_ASSERT(held && unbound() && !finished && scheduler.ready_count_ == with_peer &&
              scheduler.ready_queue(Process::PRIORITY_CRITICAL).first() == (with_peer ? &next_ready : nullptr),
              "finish one dispatch under lock with its original queue entry consumed");
  finished = true;
  // Close this single-dispatch fixture at the next worker-loop condition.
  scheduler.exit_state_.reason = Scheduler::EXIT_DONE;
}

void Scheduler::terminate_process(Locker& lock, Process* p, uint8 code) {
  CXXV_ASSERT(held && &lock == dispatch_lock && p == subject && unbound() && p->run_timestamp_ < 0 && !terminated,
              "hand a detached process to termination under lock");
  terminated = true;
  bool denied_halt = !external && executed && (outcome == Interpreter::Result::DEEP_SLEEP || outcome == Interpreter::Result::RESET);
  CXXV_ASSERT(code == (denied_halt ? SANDBOX_EXIT_DEVICE_HALT :
                       executed && outcome == Interpreter::Result::TERMINATED ? static_cast<uint8>(result_value) : kill_code),
              "preserve termination and policy exit codes");
}

void Scheduler::process_ready(Locker& lock, Process* p) {
  CXXV_ASSERT(held && &lock == dispatch_lock && p == subject && p->state() == Process::IDLE &&
              unbound() && p->run_timestamp_ < 0 && !gc_cross_processes_ && !ready,
              "hand an idle unbound process to the ready queue only after the GC barrier clears");
  ready = true;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Locker lock(&mutex);
  external = nondet_bool();
  Runner runner;
  PrimitivePolicy policy;
  policy.kind_ = external ? PrimitivePolicy::TRUSTED : PrimitivePolicy::UNTRUSTED;
  vm.scheduler_ = &scheduler;
  auto* group = new ProcessGroup(1, nullptr, nullptr, &policy);
  subject = new Process(nullptr, external ? &runner : nullptr, group, nullptr, nullptr);
  // Start the dispatch from a registered group containing the constructed
  // subject at its final address, as required by the scheduler list invariant.
  new (&group->processes_) ProcessListFromProcessGroup();
  group->add(subject);
  new (&scheduler.groups_) ProcessGroupList();
  scheduler.groups_.append(group);
  subject->program_ = external ? nullptr : &program;
  profiling = !external && nondet_bool();
  profiler.is_active_ = true;
  subject->profiler_ = profiling ? &profiler : nullptr;
  subject->object_heap_.task_ = nullptr;
  subject->set_scheduler_thread(nullptr);
  worker.interpreter()->process_ = nullptr;
  worker.interpreter()->preemption_method_header_bcp_ = &prior_header;
  subject->run_timestamp_ = -1;
  subject->set_state(Process::SCHEDULED);
  subject->set_idle_since_gc(external || nondet_bool());
  new (&scheduler.threads_) SchedulerThreadList();
  scheduler.threads_.prepend(&worker);
  scheduler.gc_condition_ = &condition;
  initial_barrier = nondet_bool();
  scheduler.gc_cross_processes_ = initial_barrier;
  unrelated = initial_barrier && nondet_bool();
  worker.gc_preemption_requested_ = false;
  if (unrelated) {
    scheduler.threads_.prepend(&other_worker);
    other_worker.interpreter()->activate(&other_active);
    other_active.signals_ = 0;
    other_active.set_scheduler_thread(&other_worker);
  }
  scheduler.gc_waiting_for_preemption_ = initial_barrier ? scheduler.request_gc_preemption(nullptr) : 0;
  CXXV_ASSERT(scheduler.gc_waiting_for_preemption_ == unrelated && !worker.gc_preemption_requested_,
              "the new dispatcher is outside the set of workers requested by the initial collector");
  initial_signals = nondet_uchar() & (Process::PREEMPT | Process::KILL);
  subject->signals_ = initial_signals;
  kill_code = nondet_uchar();
  subject->kill_exit_value_ = initial_signals & Process::KILL ? kill_code : 0;
  peer_gc = nondet_bool();
  finish_gc_during_run = nondet_bool();
  kill_during = nondet_bool();
  messaged = nondet_bool();
  new (&subject->messages_) MessageFIFO();
  if (messaged) subject->messages_.append(&message);
  unsigned state = nondet_uchar();
  CXXV_ASSUME(state <= Interpreter::Result::DEEP_SLEEP);
  outcome = static_cast<Interpreter::Result::State>(state);
  result_value = nondet_int64();
  start_time = nondet_int64();
  stop_time = nondet_int64();
  int64 prior_cpu = nondet_int64();
  CXXV_ASSUME(0 <= prior_cpu && prior_cpu <= start_time && start_time <= stop_time);
  subject->cpu_time_us_ = prior_cpu;

  scheduler.mutex_ = &mutex;
  scheduler.has_processes_ = &runnable;
  scheduler.has_threads_ = &threads_left;
  scheduler.exit_state_.reason = Scheduler::EXIT_NONE;
  scheduler.num_threads_ = 1 + unrelated;
  with_peer = nondet_bool();
  auto& queue = scheduler.ready_queue(Process::PRIORITY_CRITICAL);
  new (&queue) ProcessListFromScheduler();
  subject->priority_ = Process::PRIORITY_CRITICAL;
  queue.append(subject);
  if (with_peer) queue.append(&next_ready);
  scheduler.ready_count_ = with_peer ? 2 : 1;
  {
    Unlocker unlock(lock);
    starting = true;
    scheduler.run(&worker);
    starting = false;
    dispatch_lock = nullptr;
  }
  bool ran = initial_signals == 0;
  bool killed = (initial_signals & Process::KILL) || (ran && kill_during);
  bool device_request = ran && (outcome == Interpreter::Result::DEEP_SLEEP || outcome == Interpreter::Result::RESET);
  bool should_halt = external && device_request && !killed;
  bool exits = killed || (ran && outcome == Interpreter::Result::TERMINATED) || (!external && device_request);
  bool yielded = ran && outcome == Interpreter::Result::YIELDED && !(peer_gc && !external);
  CXXV_ASSERT(held && unbound() && subject->run_timestamp_ == -1 && clock_reads == 2 &&
              subject->cpu_time_us_ == prior_cpu + (stop_time - start_time) && executed == ran && unlocks == ran,
              "retire both bindings and account for exactly one dispatch interval");
  CXXV_ASSERT(read_header == (ran && !external && outcome == Interpreter::Result::PREEMPTED) &&
              profiler_balance == 0 && profiler_starts == profiling, "skipped runs never reuse a prior profile sample");
  CXXV_ASSERT(finished && watchdogs == 1 && notified_peer == with_peer && scheduler.num_threads_ == unrelated && peer_returned == unrelated &&
              halted == should_halt && terminated == exits && ready == (!exits && !should_halt && (!yielded || messaged)) &&
              waits == initial_barrier + (ran && peer_gc && !finish_gc_during_run && !exits && !should_halt) &&
              acknowledgments == (ran && peer_gc && !finish_gc_during_run && !external) && !worker.gc_preemption_requested_ &&
              preemptions == (ran ? kill_during + (peer_gc && !external) : 0),
              "route each result and wait for any intervening collection before requeue");
}

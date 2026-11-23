// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.cc"
#include "process_group.cc"
#undef protected
#undef private

namespace toit {
static void observe_destroy(Process*);
static void observe_destroy(ProcessGroup*);
static void observe_destroy(SystemMessage*);
#include "terminate_process.inc"
}

using namespace toit;
extern VM vm;
extern Scheduler scheduler;
extern Mutex mutex;
extern ConditionVariable condition;
extern Process peer;
VM* VM::current_ = &vm;
static Process* subject;
static ProcessGroup* owner;
static SystemMessage* notice;
static bool held, active_gc, waited, destroyed, sent, discarded, disposed, delivered, peer_remains, subject_is_boot;
static uint8 exit_value;
static unsigned encoded;

int Scheduler::next_process_id() { return 1; }
void Locker::enter() { CXXV_ASSERT(!held, "acquire an unheld scheduler lock"); held = true; }
void Locker::leave() { CXXV_ASSERT(held, "release a held scheduler lock"); held = false; }

void OS::wait(ConditionVariable* cv) {
  CXXV_ASSERT(cv == &condition && held && scheduler.gc_cross_processes_ && !destroyed &&
              subject->state() == Process::SUSPENDED_AWAITING_GC &&
              owner->pending_teardowns_ == 0, "wait for the collector before detaching the process");
  scheduler.gc_cross_processes_ = false;
  waited = true;
}

void MessageEncoder::encode_process_message(uint8* data, uint8 value) {
  CXXV_ASSERT(held && waited == active_gc && !scheduler.gc_cross_processes_ &&
              subject->state() == Process::RUNNING && owner->pending_teardowns_ == 1 && value == exit_value &&
              data == notice->data(), "prepare the termination notice after pinning the group");
  ++encoded;
}

void toit::observe_destroy(Process* p) {
  CXXV_ASSERT(!held && !destroyed && waited == active_gc && encoded == 1 && p == subject &&
              owner->pending_teardowns_ == 1 && !owner->is_not_linked() &&
              owner->processes_.first() != p && scheduler.boot_process_ != p &&
              scheduler.boot_process_exiting_ == subject_is_boot,
              "destroy outside the lock after detaching both the group member and boot routing target");
  if (owner->processes_.first() == &peer && nondet_bool()) {
    // Another thread can complete its own exit during the unlocked destructor.
    held = true;
    owner->begin_process_teardown(&peer);
    CXXV_ASSERT(!owner->finish_process_teardown(), "a concurrent final member cannot release the active destructor's image");
    held = false;
    peer_remains = false;
  }
  destroyed = true;
}

message_err_t Scheduler::send_system_message(Locker&, SystemMessage* msg) {
  CXXV_ASSERT(held && destroyed && !sent && !disposed && msg == notice && boot_process_ != subject && !boot_process_exiting_,
              "route the termination notice after destruction under the scheduler lock");
  sent = true;
  return delivered ? MESSAGE_OK : MESSAGE_NO_SUCH_RECEIVER;
}

void toit::observe_destroy(SystemMessage* msg) {
  CXXV_ASSERT(held && sent && !delivered && !discarded && msg == notice, "discard an undelivered notice once");
  discarded = true;
}

void toit::observe_destroy(ProcessGroup* g) {
  CXXV_ASSERT(held && destroyed && sent && !disposed && g == owner && owner->is_not_linked() &&
              owner->pending_teardowns_ == 0 && !peer_remains, "unlink and dispose the group only after all users finish");
  disposed = true;
}

void toit::fail(const char*, ...) { CXXV_ASSERT(false, "fixture contains valid group members"); abort(); }

int main() {
  vm.scheduler_ = &scheduler;
  scheduler.mutex_ = &mutex;
  PrimitivePolicy policy;
  owner = new ProcessGroup(1, nullptr, nullptr, &policy);
  notice = new SystemMessage(SystemMessage::TERMINATED, 1, 0);
  uint8 payload[MESSAGING_PROCESS_MESSAGE_SIZE];
  notice->data_ = payload;
  Locker locker(&mutex);
  subject = new Process(nullptr, nullptr, owner, notice, nullptr);
  // Registration and heap construction precede this exit protocol. Install
  // the live member list explicitly, as in the group lifetime proof.
  new (&owner->processes_) ProcessListFromProcessGroup();
  owner->add(subject);
  peer_remains = nondet_bool();
  if (peer_remains) owner->add(&peer);
  new (&scheduler.groups_) ProcessGroupList();
  scheduler.groups_.append(owner);
  scheduler.num_processes_ = 1 + peer_remains;
  scheduler.num_run_time_limited_processes_ = 1;
  subject_is_boot = nondet_bool();
  scheduler.boot_process_ = subject_is_boot ? subject : nullptr;
  scheduler.boot_process_exiting_ = false;
  subject->set_state(Process::RUNNING);
  subject->set_scheduler_thread(nullptr);
  active_gc = nondet_bool();
  scheduler.gc_cross_processes_ = active_gc;
  scheduler.gc_waiting_for_preemption_ = 0;
  scheduler.gc_condition_ = &condition;
  delivered = nondet_bool();
  exit_value = nondet_uchar();
  scheduler.terminate_process(locker, subject, exit_value);
  CXXV_ASSERT(destroyed && sent && discarded == !delivered && disposed == !peer_remains &&
              scheduler.groups_.is_empty() == disposed, "retain the group precisely while a peer remains registered");
}

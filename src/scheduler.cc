// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "resource.h"
#include "flags.h"
#include "hw_perf.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "os.h"
#include "process.h"
#include "process_group.h"
#include "scheduler.h"
#include "vm.h"

#include  <stdio.h>
#include  <signal.h>
#include  <stdlib.h>

#ifdef TOIT_FREERTOS
#include <freertos/FreeRTOS.h>
#endif  // TOIT_FREERTOS


namespace toit {

// The maximum amount of us a process is allowed to run without
// returning to the scheduler.
static const int64 PROCESS_MAX_RUN_TIME_US = 10 * 1000 * 1000;

#ifdef TOIT_ESP32
static const bool PROCESS_MAX_RUN_TIME_ENFORCE = true;
#else
static const bool PROCESS_MAX_RUN_TIME_ENFORCE = false;
#endif

void SchedulerThread::entry() {
  scheduler_->run(this);
}

Scheduler::Scheduler()
    : mutex_(OS::allocate_mutex(2, "Scheduler"))
    , has_processes_(OS::allocate_condition_variable(mutex_))
    , has_threads_(OS::allocate_condition_variable(mutex_))
    , gc_condition_(OS::allocate_condition_variable(mutex_))
    , gc_cross_processes_(false)
    , gc_waiting_for_preemption_(0)
    , num_processes_(0)
    , next_group_id_(0)
    , next_process_id_(0)
    , num_threads_(0)
    , max_threads_(OS::num_cores())
    , boot_process_(null) {
  Locker locker(mutex_);
#ifdef TOIT_FREERTOS
  // On FreeRTOS we immediately start two threads (the main one and a second
  // one for the second core) because we don't want to handle allocation
  // failures when trying to start them later.
  while (num_threads_ < max_threads_) {
    start_thread(locker);
  }
#endif
}

Scheduler::~Scheduler() {
  for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
    ASSERT(ready_queue_[i].is_empty());
  }
  ASSERT(groups_.is_empty());
  ASSERT(threads_.is_empty());
  OS::dispose(gc_condition_);
  OS::dispose(has_threads_);
  OS::dispose(has_processes_);
  OS::dispose(mutex_);
}

SystemMessage* Scheduler::new_process_message(SystemMessage::Type type, int gid) {
  uint8* data = unvoid_cast<uint8*>(malloc(MESSAGING_PROCESS_MESSAGE_SIZE));
  if (data == NULL) return NULL;

  // We must encode a proper message in the data. Otherwise, we cannot free it
  // later without running into issues when we traverse the data to find pointers
  // to external memory areas.
  MessageEncoder::encode_process_message(data, 0);  // Does not take over data.

  SystemMessage* result = _new SystemMessage(type, gid, -1, data);  // Takes over data.
  if (result == null) {
    free(data);
  }
  return result;
}

Process* Scheduler::new_boot_process(Locker& locker, Program* program, int group_id) {
  InitialMemoryManager manager;
  { // Allocation takes the memory lock which must happen without holding
    // the scheduler lock.
    Unlocker unlocker(locker);
    bool ok = manager.allocate();
    // We assume that the allocation succeeds since we can't run out of
    // memory while booting.
    ASSERT(ok);
  }

  if (next_process_id_ == INVALID_PROCESS_ID) return null;
  ProcessGroup* group = ProcessGroup::create(group_id, program, null, PrimitivePolicy::system());
  // A malformed format-2 program has no method table (the reason is on
  // stderr).
  if (group == null) FATAL("cannot create the boot process group");
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group_id);
  manager.global_variables = program->global_variables.copy();
  ASSERT(manager.global_variables);  // Booting system.
  Process* process = _new Process(program, group, termination, &manager);
  ASSERT(process);
  // Start the boot process with a high priority. It can always
  // be adjusted later if necessary.
  update_priority(locker, process, Process::PRIORITY_HIGH);
  return process;
}

#ifdef TOIT_FREERTOS

Scheduler::ExitState Scheduler::run_boot_program(Program* program, int group_id) {
  Locker locker(mutex_);
  Process* process = new_boot_process(locker, program, group_id);
  if (process == null) return ExitState(EXIT_ERROR, 1);
  return launch_program(locker, process);
}

#else

Scheduler::ExitState Scheduler::run_boot_program(Program* program, char** argv, int group_id) {
  Locker locker(mutex_);
  Process* process = new_boot_process(locker, program, group_id);
  if (process == null) return ExitState(EXIT_ERROR, 1);
  process->set_main_arguments(argv);
  return launch_program(locker, process);
}

Scheduler::ExitState Scheduler::run_boot_program(
    Program* program,
    SnapshotBundle system,
    SnapshotBundle application,
    char** argv,
    int group_id) {
  Locker locker(mutex_);
  Process* process = new_boot_process(locker, program, group_id);
  if (process == null) return ExitState(EXIT_ERROR, 1);
  process->set_main_arguments(argv);
  process->set_spawn_arguments(system, application);
  return launch_program(locker, process);
}

#endif

Scheduler::ExitState Scheduler::launch_program(Locker& locker, Process* process) {
  ProcessGroup* group = process->group();
  Interpreter interpreter;
  interpreter.activate(process);
  interpreter.prepare_process();
  interpreter.deactivate();
  // The boot process runs with the system policy (see new_boot_process).
  ASSERT(process->is_privileged());

  // Update the state and start the boot process.
  ASSERT(boot_process_ == null);
  groups_.prepend(group);
  boot_process_ = process;
  add_process(locker, process);

  tick_schedule(locker, OS::get_monotonic_time(), true);
  while (num_processes_ > 0 && num_threads_ > 0) {
    int64 time = OS::get_monotonic_time();
    int64 next = tick_next();
    if (time >= next) {
      tick(locker, time);
    } else {
      int64 delay_us = next - time;
      OS::wait_us(has_threads_, delay_us);
    }
  }

  if (!has_exit_reason()) {
    exit_state_.reason = EXIT_DONE;
  }

  while (SchedulerThread* thread = threads_.remove_first()) {
    Unlocker unlock(locker);
    thread->join();
    delete thread;
  }

  for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
    ProcessListFromScheduler& ready_queue = ready_queue_[i];
    while (ready_queue.remove_first()) {
      // Clear out the list of ready processes, so we don't have any dangling
      // pointers to processes that we delete in a moment.
      ready_count_--;
    }
  }

  while (ProcessGroup* group = groups_.remove_first()) {
    while (Process* process = group->processes().remove_first()) {
      Unlocker unlock(locker);
      // TODO(kasper): We should let any ExternalSystemMessageHandler know that
      // their process has been deleted.
      delete process;
    }
    delete group;
  }

  return exit_state_;
}

int Scheduler::next_group_id() {
  Locker locker(mutex_);
  return next_group_id_++;
}

int Scheduler::run_program(Program* program, MessageEncoder* arguments, ProcessGroup* group, InitialMemoryManager* initial_memory) {
  Locker locker(mutex_);
  if (next_process_id_ == INVALID_PROCESS_ID) return QUOTA_EXCEEDED_PROCESS_ID;
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group->id());
  if (termination == null) {
    return INVALID_PROCESS_ID;
  }
  Process* process = _new Process(program, group, termination, initial_memory);  // Takes over initial_memory.
  if (process == null) {
    delete termination;
    return INVALID_PROCESS_ID;
  }
  process->set_main_arguments(arguments->take_buffer());  // Neuters the encoder.

  Interpreter interpreter;
  interpreter.activate(process);
  interpreter.prepare_process();
  interpreter.deactivate();

  groups_.append(group);
  add_process(locker, process);
  return process->id();
}

Process* Scheduler::run_external(ProcessRunner* runner) {
  int group_id = next_group_id();
  Locker locker(mutex_);
  if (next_process_id_ == INVALID_PROCESS_ID) return null;
  ProcessGroup* group = ProcessGroup::create(group_id, null);
  if (group == null) return null;
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group_id);
  if (termination == null) {
    delete group;
    return null;
  }
  Process* process = _new Process(runner, group, termination);
  if (process == null) {
    delete group;
    delete termination;
    return null;
  }
  groups_.append(group);
  // It is important that we let the runner know the process before
  // we add the process and start scheduling it. This way, we can
  // be sure that we never call ProcessRunner::run() before the
  // process has been registered.
  runner->set_process(process);
  add_process(locker, process);
  return process;
}

message_err_t Scheduler::send_system_message(SystemMessage* message) {
  Locker locker(mutex_);
  message_err_t result = send_system_message(locker, message);
  if (result != MESSAGE_OK) delete message;
  return result;
}

message_err_t Scheduler::send_message(int process_id, Message* message, bool free_on_failure) {
  HW_PERF_SCOPE(HWP_SEND);
  Locker locker(mutex_);
  Process* p = find_process(locker, process_id);
  if (p == null) {
    if (free_on_failure) delete message;
    return MESSAGE_NO_SUCH_RECEIVER;
  }
  if (!p->_append_message(message)) {
    if (free_on_failure) delete message;
    return MESSAGE_QUOTA_EXCEEDED;
  }
  process_ready(locker, p);
  return MESSAGE_OK;
}

message_err_t Scheduler::send_message_from(Process* sender, int process_id, SystemMessage* message) {
  HW_PERF_SCOPE(HWP_SEND);
  Locker locker(mutex_);
  // A process can't forge the scheduler's life-cycle notices, on either
  // route: without a boot process, a TERMINATED notice on the system route
  // decides the exit state (send_system_message).
  if (SystemMessage::is_scheduler_type(message->type())) {
    delete message;
    return MESSAGE_PERMISSION_DENIED;
  }
  const PrimitivePolicy* policy = sender->policy();
  if (process_id < 0) {
    message_err_t result = send_system_message(locker, message);
    if (result != MESSAGE_OK) delete message;
    return result;
  }
  Process* receiver = find_process(locker, process_id);
  if (policy->restricts_messaging()) {
    // Check the target before looking at whether it exists, so a sandboxed
    // process can't probe for process ids.
    bool allowed = (receiver != null && receiver == boot_process_)
        || (receiver != null && receiver->group() == sender->group())
        || sender->group()->may_send_to(process_id);
    if (!allowed) {
      delete message;
      return MESSAGE_PERMISSION_DENIED;
    }
  }
  if (receiver == null) {
    delete message;
    return MESSAGE_NO_SUCH_RECEIVER;
  }
  // A process in a messaging-restricted group that receives an RPC request
  // may reply to the requester (it may always send to the system process).
  // If its allowed-target set is full, the request is refused like a
  // request to a full mailbox.
  ProcessGroup* receiver_group = receiver->group();
  bool needs_reply_grant = receiver_group != sender->group() &&
                           receiver_group->policy()->restricts_messaging() &&
                           message->type() == SYSTEM_RPC_REQUEST &&
                           sender != boot_process_;
  if (!receiver->_append_message(message, needs_reply_grant ? sender->id() : -1)) {
    delete message;
    return MESSAGE_QUOTA_EXCEEDED;
  }
  process_ready(locker, receiver);
  return MESSAGE_OK;
}

Scheduler::GrantResult Scheduler::grant_send(int pid, int target) {
  Locker locker(mutex_);
  Process* process = find_process(locker, pid);
  if (process == null) return GRANT_NO_SUCH_PROCESS;
  ProcessGroup* group = process->group();
  if (!group->policy()->restricts_messaging()) return GRANT_OK;
  // The system process and the own group are always allowed targets, so
  // they don't take up room in the allowed-target set.
  Process* target_process = find_process(locker, target);
  if (target_process != null &&
      (target_process == boot_process_ || target_process->group() == group)) {
    return GRANT_OK;
  }
  return group->grant_send_to(target) ? GRANT_OK : GRANT_QUOTA_EXCEEDED;
}

int Scheduler::policy_kind(int pid) {
  Locker locker(mutex_);
  Process* process = find_process(locker, pid);
  if (process == null) return -1;
  return process->policy()->kind();
}

message_err_t Scheduler::send_system_message(Locker& locker, SystemMessage* message) {
  if (boot_process_ != null) {
    if (!boot_process_->_append_message(message)) return MESSAGE_QUOTA_EXCEEDED;
    process_ready(locker, boot_process_);
    return MESSAGE_OK;
  }

  // Default processing of system messages.
  switch (message->type()) {
    case SystemMessage::TERMINATED: {
      // The exiting boot process decides the exit state (see terminate_process).
      if (boot_process_exiting_) break;
      int value;
      if (MessageDecoder::decode_process_message(message->data(), &value)) {
        ExitReason reason = (value == 0) ? EXIT_DONE : EXIT_ERROR;
        terminate_execution(locker, ExitState(reason, value));
      }
      break;
    }
    case SystemMessage::SPAWNED: {
      // Do nothing. With no boot process, we don't care about newly spawned processes.
      break;
    }
    default:
      // Without a boot process there is nobody to handle the message. Drop
      // it instead of aborting the VM; any process can send these.
      break;
  }

  delete message;
  return MESSAGE_OK;
}

void Scheduler::send_notify_message(ObjectNotifier* notifier) {
  Locker locker(mutex_);
  Process* process = notifier->process();
  if (process->state() == Process::TERMINATING) return;
  // Notifications are not subject to mailbox quotas, so this can't fail.
  bool ok = process->_append_message(notifier->message());
  ASSERT(ok);
  USE(ok);
  process_ready(locker, process);
}

bool Scheduler::signal_process(Process* sender, int target_id, Process::Signal signal) {
  if (sender != boot_process_) return false;

  Locker locker(mutex_);
  Process* target = find_process(locker, target_id);
  if (target == null) return false;

  target->signal(signal);
  process_ready(locker, target);
  return true;
}

int Scheduler::spawn(Program* program, ProcessGroup* process_group, int priority,
                     Method method, MessageEncoder* arguments, InitialMemoryManager* initial_memory) {
  Locker locker(mutex_);

  word max_processes = process_group->policy()->quotas().max_processes;
  if (max_processes > 0 && process_group->process_count() >= max_processes) {
    return QUOTA_EXCEEDED_PROCESS_ID;
  }

  if (next_process_id_ == INVALID_PROCESS_ID) return QUOTA_EXCEEDED_PROCESS_ID;
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, process_group->id());
  if (!termination) return INVALID_PROCESS_ID;

  // Acquire both messages before the constructor registers the new process.
  SystemMessage* spawned = new_process_message(SystemMessage::SPAWNED, process_group->id());
  if (!spawned) {
    delete termination;
    return INVALID_PROCESS_ID;
  }
  // Takes over the initial_memory and termination message on success.
  Process* process = _new Process(program, process_group, termination, method, initial_memory);
  if (!process) {
    delete spawned;
    delete termination;
    return INVALID_PROCESS_ID;
  }
  int pid = process->id();
  spawned->set_pid(pid);
  // Send the SPAWNED message before returning from the call to spawn. This is necessary
  // to make sure the system doesn't conclude that there are no processes left just after
  // spawning, but before the spawned process starts up.
  if (send_system_message(locker, spawned) != MESSAGE_OK) {
    // The system process would never learn of this pid, so the child must
    // not run. Today this is unreachable: the boot process has the system
    // policy, whose mailbox has no quota, and a SPAWNED notice is charged
    // one message and no bytes. The child never ran and has no arguments
    // yet (the caller's encoder keeps them, nothing is transferred); its
    // destructor frees the termination notice and the initial memory.
    delete spawned;
    process_group->begin_process_teardown(process);
    { Unlocker unlock(locker);
      delete process;
    }
    // The spawning process is a member of the group and keeps it alive.
    bool last = process_group->finish_process_teardown();
    ASSERT(!last);
    USE(last);
    return QUOTA_EXCEEDED_PROCESS_ID;
  }
  process->set_spawn_arguments(arguments->take_buffer());  // Neuters the encoder.
  if (priority != -1) process->set_target_priority(priority);
  new_process(locker, process);
  return pid;
}

void Scheduler::new_process(Locker& locker, Process* process) {
  Interpreter interpreter;
  interpreter.activate(process);
  interpreter.prepare_process();
  interpreter.deactivate();

  add_process(locker, process);
}

// Make sure we compute a unique id for each call.
int Scheduler::next_process_id() {
  ASSERT(is_locked());
  int id = next_process_id_;
  if (id == INVALID_PROCESS_ID) return id;
  int64 next = static_cast<int64>(id) + 1;
  next_process_id_ = next <= INT32_MAX && Smi::is_valid(next) ? static_cast<int>(next) : INVALID_PROCESS_ID;
  return id;
}

int Scheduler::process_count() {
  Locker locker(mutex_);
  return num_processes_;
}

Process* Scheduler::dequeue_ready_process() {
  for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
    if (ready_queue_[i].is_empty()) {
      continue;
    }
    Process* process = ready_queue_[i].remove_first();
    ready_count_--;
    return process;
  }
  return null;
}

void Scheduler::run(SchedulerThread* scheduler_thread) {
  Locker locker(mutex_);

  // Once started, a SchedulerThread continues to run until the whole system
  // is shutting down with an exit reason. This makes it possible to preallocate
  // all OS threads at startup on platforms that may have a hard time starting
  // such threads later due to memory pressure.
  while (!has_exit_reason()) {
    // Service the platform watchdog (a no-op where there is none).
    OS::feed_watchdog();

    if (ready_count_ == 0) {
      HW_PERF_SCOPE(HWP_IDLE);
      OS::wait(has_processes_);
      continue;
    }

    Process* process = dequeue_ready_process();
    ASSERT(process->state() == Process::SCHEDULED);

    if (ready_count_ > 0) {
      // Notify potential other thread that there are more processes ready.
      OS::signal(has_processes_);
    }

    { HW_PERF_SCOPE(HWP_PROCESS);
      run_process(locker, process, scheduler_thread);
    }
  }

  // Notify potential other thread, that no more processes are left.
  OS::signal(has_processes_);

  num_threads_--;

  OS::signal(has_threads_);
}

bool Scheduler::is_running(const Program* program) {
  Locker locker(mutex_);
  for (ProcessGroup* group : groups_) {
    if (group->program() == program) {
      return true;
    }
  }
  return false;
}

bool Scheduler::kill(const Program* program) {
  Locker locker(mutex_);
  for (ProcessGroup* group : groups_) {
    if (group->program() != program) continue;
    for (Process* p : group->processes_) {
      p->signal(Process::KILL);
      process_ready(locker, p);
    }
    return true;
  }
  return false;
}

void Scheduler::gc(Process* process, bool malloc_failed, bool try_hard) {
  HW_PERF_SCOPE(HWP_GC);
  bool doing_idle_process_gc = try_hard || malloc_failed || (process && process->system_refused_memory());
  bool doing_cross_process_gc = false;
  // Avoid getting time if we don't need it.  Best-case scavenges
  // are around 1us on desktop and this call is surprisingly expensive.
  uint64 start = try_hard ? OS::get_monotonic_time() : 0;
#ifdef TOIT_GC_LOGGING
  bool is_boot_process = process && VM::current()->scheduler()->is_boot_process(process);
#endif

  if (try_hard) {
    Locker locker(mutex_);
    if (gc_cross_processes_) {
      doing_idle_process_gc = false;
    } else {
      doing_cross_process_gc = true;
      gc_cross_processes_ = true;
      gc_waiting_for_preemption_ = request_gc_preemption(process);

      // We try to get the processes currently running on the OS threads
      // to be preempted, but since we only GC them if we can get them to
      // be "suspendable" or "suspended" later, we can live with this
      // timing out and not succeeding.
      int64 deadline = start + 1000000LL;  // Wait for up to 1 second.
      while (gc_waiting_for_preemption_ > 0) {
        if (!OS::wait_us(gc_condition_, deadline - OS::get_monotonic_time())) {
#ifdef TOIT_GC_LOGGING
          printf("[gc @ %p%s | timed out waiting for %d processes to stop]\n",
              process, is_boot_process ? "*" : " ",
              gc_waiting_for_preemption_);
#endif
          gc_waiting_for_preemption_ = 0;
        }
      }
    }
  }

  size_t gcs = 0;
  USE(gcs);
  if (doing_idle_process_gc) {
    ProcessListFromScheduler targets;
    { Locker locker(mutex_);
      select_gc_targets(locker, &targets, doing_cross_process_gc);
    }

    gcs = scan_gc_targets(targets, try_hard);

    { Locker locker(mutex_);
      resume_gc_targets(locker, &targets);
    }
  }

  if (process && process->program() != null) {
    // Not external process.
    process->gc(try_hard);
    gcs++;
  }

  if (doing_cross_process_gc) {
    Locker locker(mutex_);
    gc_cross_processes_ = false;
#ifdef TOIT_GC_LOGGING
    int64 microseconds = OS::get_monotonic_time() - start;
    printf("[gc @ %p%s | cross process gc with %zu gcs, took %d.%03dms]\n",
        process, VM::current()->scheduler()->is_boot_process(process) ? "*" : " ",
        gcs,
        static_cast<int>(microseconds / 1000),
        static_cast<int>(microseconds % 1000));
#endif
    OS::signal_all(gc_condition_);
  }
}

void Scheduler::add_process(Locker& locker, Process* process) {
  num_processes_++;
  if (process->policy()->quotas().limits_run_time()) num_run_time_limited_processes_++;
  process_ready(locker, process);
}

Object* Scheduler::process_stats(Array* array, int group_id, int process_id, Process* calling_process) {
  Locker locker(mutex_);
  ProcessGroup* group = null;
  for (auto g : groups_) {
    if (g->id() == group_id) group = g;
  }
  if (group == null) return calling_process->null_object();
  Process* subject_process = group->lookup(process_id);
  if (subject_process == null) return calling_process->null_object();  // Process not found.
  uword length = array->length();
#ifdef TOIT_ESP32
  multi_heap_info_t info;
  heap_caps_get_info(&info, MALLOC_CAP_8BIT);
#else
  struct multi_heap_info_t {
      uword total_free_bytes;
      uword largest_free_block;
  } info;
  info.total_free_bytes = Smi::MAX_SMI_VALUE;
  info.largest_free_block = Smi::MAX_SMI_VALUE;
#endif
  uword max = Smi::MAX_SMI_VALUE;
  switch (length) {
    default:
    case 11:
      array->at_put(10, Smi::from(subject_process->gc_count(COMPACTING_GC)));
      [[fallthrough]];
    case 10:
      array->at_put(9, Smi::from(subject_process->gc_count(FULL_GC)));
      [[fallthrough]];
    case 9:
      array->at_put(8, Smi::from(Utils::min(max, info.largest_free_block)));
      [[fallthrough]];
    case 8:
      array->at_put(7, Smi::from(Utils::min(max, info.total_free_bytes)));
      [[fallthrough]];
    case 7:
      array->at_put(6, Smi::from(process_id));
      [[fallthrough]];
    case 6:
      array->at_put(5, Smi::from(group_id));
      [[fallthrough]];
    case 5: {
      Object* total = Primitive::integer(subject_process->object_heap()->total_bytes_allocated(), calling_process);
      if (Primitive::is_error(total)) return total;
      array->at_put(4, total);
    }
      [[fallthrough]];
    case 4:
      array->at_put(3, Smi::from(subject_process->message_count()));
      [[fallthrough]];
    case 3:
      array->at_put(2, Smi::from(subject_process->object_heap()->bytes_reserved()));
      [[fallthrough]];
    case 2:
      array->at_put(1, Smi::from(subject_process->object_heap()->bytes_allocated()));
      [[fallthrough]];
    case 1:
      array->at_put(0, Smi::from(subject_process->gc_count(NEW_SPACE_GC)));
      [[fallthrough]];
    case 0:
      (void)0;  // Do nothing.
  }
  return array;
}

void Scheduler::run_process(Locker& locker, Process* process, SchedulerThread* scheduler_thread) {
  wait_for_any_gc_to_complete(locker, process, Process::RUNNING);
  process->set_scheduler_thread(scheduler_thread);
  process->set_run_timestamp(OS::get_monotonic_time());

  ProcessRunner* runner = process->runner();
  bool interpreted = (runner == null);
  Interpreter::Result result(Interpreter::Result::PREEMPTED);
  uint8* preemption_method_header_bcp = null;
  if (interpreted) {
    if (process->profiler() && process->profiler()->is_active()) {
      notify_profiler(locker, 1);
    }

    Interpreter* interpreter = scheduler_thread->interpreter();
    interpreter->activate(process);
    process->set_idle_since_gc(false);
    if (process->signals() == 0) {
      { Unlocker unlock(locker);
        HW_PERF_SCOPE(HWP_RUN);
        result = interpreter->run();
      }
      if (result.state() == Interpreter::Result::PREEMPTED) {
        preemption_method_header_bcp = interpreter->preemption_method_header_bcp();
      }
    }
    interpreter->deactivate();

    if (process->profiler() && process->profiler()->is_active()) {
      notify_profiler(locker, -1);
    }
  } else if (process->signals() == 0) {
    ASSERT(process->idle_since_gc());
    Unlocker unlock(locker);
    result = runner->run();
  }

  process->add_cpu_time_us(process->run_time_us(OS::get_monotonic_time()));
  process->clear_run_timestamp();
  process->set_scheduler_thread(null);
  acknowledge_gc_preemption(scheduler_thread);

  // A process whose policy does not allow it to act on the device is
  // terminated with an error instead of putting the device to sleep or
  // resetting it.
  if ((result.state() == Interpreter::Result::DEEP_SLEEP ||
       result.state() == Interpreter::Result::RESET) &&
      !process->policy()->may_halt_device()) {
    result = Interpreter::Result(Interpreter::Result::TERMINATED, SANDBOX_EXIT_DEVICE_HALT);
  }

  while (result.state() != Interpreter::Result::TERMINATED) {
    uint32 signals = process->signals();
    if (signals == 0) break;
    if (signals & Process::KILL) {
      // Processes killed for violating their policy report a specific exit
      // value. Other kills report 0, as before.
      result = Interpreter::Result(Interpreter::Result::TERMINATED, process->kill_exit_value());
      // TODO(kasper): Would it be meaningful to clear the KILL
      // signal bits here like the other cases?
    } else if (signals & Process::PREEMPT) {
      result = Interpreter::Result(Interpreter::Result::PREEMPTED);
      process->clear_signal(Process::PREEMPT);
    } else {
      UNREACHABLE();
    }
  }

  switch (result.state()) {
    case Interpreter::Result::PREEMPTED: {
      HW_PERF_COUNT(HWP_PREEMPTED);
      Profiler* profiler = process->profiler();
      Task* task = process->task();
      if (preemption_method_header_bcp && profiler && task && profiler->should_profile_task(task->id())) {
        Stack* stack = task->stack();
        if (stack) {
          int bci = stack->absolute_bci_at_preemption(process->program());
          if (bci >= 0) {
            int method = process->program()->absolute_bci_from_bcp(preemption_method_header_bcp);
            profiler->register_method(method);
            profiler->increment(bci);
          }
        }
      }
      wait_for_any_gc_to_complete(locker, process, Process::IDLE);
      process_ready(locker, process);
      break;
    }

    case Interpreter::Result::YIELDED:
      HW_PERF_COUNT(HWP_YIELDED);
      wait_for_any_gc_to_complete(locker, process, Process::IDLE);
      if (process->has_messages()) {
        process_ready(locker, process);
      }
      break;

    case Interpreter::Result::TERMINATED:
      terminate_process(locker, process, result.value());
      break;

    case Interpreter::Result::DEEP_SLEEP: {
      ExitState exit(EXIT_DEEP_SLEEP, result.value());
      terminate_execution(locker, exit);
      break;
    }

    case Interpreter::Result::RESET: {
      ExitState exit(EXIT_RESET);
      terminate_execution(locker, exit);
      break;
    }
  }
}

void Scheduler::terminate_process(Locker& locker, Process* process, uint8 exit_value) {
  wait_for_any_gc_to_complete(locker, process, Process::RUNNING);

  int id = process->id();
  ProcessGroup* group = process->group();
  if (process->policy()->quotas().limits_run_time()) num_run_time_limited_processes_--;
  group->begin_process_teardown(process);
  ASSERT(group->lookup(id) == null);
  SystemMessage* message = process->take_termination_message(exit_value);
  // Nothing is routed to the boot process once its destructor runs. Its own
  // termination message, sent below, decides the exit state. Until then,
  // send_system_message drops the termination messages of other processes
  // (for example those it killed on its way out) so that they can't decide
  // the exit state first.
  bool is_boot_process = process == boot_process_;
  if (is_boot_process) {
    boot_process_ = null;
    boot_process_exiting_ = true;
  }

  // Deleting processes might need to take the event source lock, so we have
  // to unlock the scheduler to not get into a deadlock with the delivery of
  // an asynchronous event that needs to call [process_ready] and thus also
  // take the scheduler lock.
  { Unlocker unlock(locker);
    delete process;
  }

  num_processes_--;
  if (is_boot_process) boot_process_exiting_ = false;

  // Send the termination message after having deleted the process. This ensures
  // that the message for the boot process will not be assumed to be handled by
  // the boot process that is going away.
  if (send_system_message(locker, message) != MESSAGE_OK) {
#ifdef TOIT_FREERTOS
    printf("[message: cannot send termination message for pid %d]\n", id);
#endif
    delete message;
  }

  if (group->finish_process_teardown()) {
    group->unlink();
    delete group;
  }
}

int Scheduler::boot_process_id() {
  Locker locker(mutex_);
  return boot_process_ ? boot_process_->id() : INVALID_PROCESS_ID;
}

int Scheduler::get_priority(int pid) {
  Locker locker(mutex_);
  Process* process = find_process(locker, pid);
  return process ? process->priority() : -1;
}

bool Scheduler::set_priority(int pid, uint8 priority) {
  Locker locker(mutex_);
  Process* process = find_process(locker, pid);
  if (!process) return false;
  update_priority(locker, process, priority);
  return true;
}

void Scheduler::update_priority(Locker& locker, Process* process, uint8 priority) {
  process->set_target_priority(priority);
  if (process->state() == Process::RUNNING) {
    process->signal(Process::PREEMPT);
  } else if (process->state() == Process::SCHEDULED) {
    ready_queue(process->priority()).remove(process);
    ready_count_--;
    process->set_state(Process::IDLE);
    process_ready(locker, process);
  }
}

int Scheduler::request_gc_preemption(Process* process) {
  int count = 0;
  for (SchedulerThread* thread : threads_) {
    Process* running_process = thread->mark_for_gc_preemption(process);
    if (running_process != null) {
      running_process->signal(Process::PREEMPT);
      count++;
    }
  }
  return count;
}

void Scheduler::acknowledge_gc_preemption(SchedulerThread* worker) {
  // A worker may return after the collector timed out. Each new barrier
  // replaces every worker's mark before releasing the scheduler lock.
  if (worker->take_gc_preemption_request() && gc_waiting_for_preemption_ > 0) {
    if (--gc_waiting_for_preemption_ == 0) OS::signal_all(gc_condition_);
  }
}

void Scheduler::select_gc_targets(Locker& locker, ProcessListFromScheduler* targets, bool cross_owner) {
  for (ProcessGroup* group : groups_) {
    for (Process* target : group->processes_) {
      if (claim_gc_target(locker, target, cross_owner)) {
        targets->append(target);
      }
    }
  }
}

bool Scheduler::claim_gc_target(Locker& locker, Process* target, bool doing_cross_process_gc) {
  if (target->program() == null || target->idle_since_gc()) return false;
  // Only the collector that holds the cross-process barrier can scan its
  // waiters. An ordinary suspension already belongs to another collector.
  if (target->state() == Process::SUSPENDED_AWAITING_GC) return doing_cross_process_gc;
  if (target->state() != Process::IDLE && target->state() != Process::SCHEDULED) return false;
  gc_suspend_process(locker, target);
  return true;
}

void Scheduler::gc_suspend_process(Locker& locker, Process* process) {
  ASSERT(process->state() != Process::RUNNING);  // Preempt the process first.
  ASSERT(process->state() != Process::SUSPENDED_AWAITING_GC);
  ASSERT(!process->is_suspended());
  if (process->state() == Process::IDLE) {
    process->set_state(Process::SUSPENDED_IDLE);
  } else if (process->state() == Process::SCHEDULED) {
    process->set_state(Process::SUSPENDED_SCHEDULED);
    ready_queue(process->priority()).remove(process);
    ready_count_--;
  }
  ASSERT(process->is_suspended());
}

void Scheduler::scan_gc_target(Process* target, bool try_hard) {
  if (target->gc(try_hard) != NEW_SPACE_GC) {
    Locker locker(mutex_);
    target->set_idle_since_gc(true);
  }
}

size_t Scheduler::scan_gc_targets(ProcessListFromScheduler& targets, bool try_hard) {
  size_t scanned = 0;
  for (Process* target : targets) {
    scan_gc_target(target, try_hard);
    scanned++;
  }
  return scanned;
}

void Scheduler::resume_gc_targets(Locker& locker, ProcessListFromScheduler* targets) {
  while (!targets->is_empty()) {
    Process* target = targets->remove_first();
    if (target->state() != Process::SUSPENDED_AWAITING_GC) {
      gc_resume_process(locker, target);
    }
  }
}

void Scheduler::gc_resume_process(Locker& locker, Process* process) {
  ASSERT(process->state() != Process::SUSPENDED_AWAITING_GC);
  ASSERT(process->is_suspended());
  bool was_scheduled = process->state() == Process::SUSPENDED_SCHEDULED;
  process->set_state(Process::IDLE);
  if (was_scheduled) process_ready(locker, process);
  ASSERT(!process->is_suspended());
}

void Scheduler::wait_for_any_gc_to_complete(Locker& locker, Process* process, Process::State new_state) {
  ASSERT(process->scheduler_thread() == null);
  if (gc_cross_processes_) {
    process->set_state(Process::SUSPENDED_AWAITING_GC);
    do {
      OS::wait(gc_condition_);
    } while (gc_cross_processes_);
  }
  process->set_state(new_state);
}

SchedulerThread* Scheduler::start_thread(Locker& locker) {
  if (num_threads_ == max_threads_) return null;
  // On FreeRTOS we start both threads at boot time and then don't start
  // other threads. This should be enough, and should ensure that allocation
  // does not fail. On other platforms we assume that allocation will
  // not fail.
  SchedulerThread* new_thread = _new SchedulerThread(this);
  if (new_thread == null) FATAL("OS thread spawn failed");
  int core = num_threads_++;
  threads_.prepend(new_thread);
  // TODO(kasper): Try to get back to only using 4KB for the stacks. We
  // bumped the limit to support SD card mounting on ESP32.
  if (!new_thread->spawn(8 * KB, core)) FATAL("OS thread spawn failed");
  return new_thread;
}

void Scheduler::process_ready(Process* process) {
  Locker locker(mutex_);
  process_ready(locker, process);
}

void Scheduler::process_ready(Locker& locker, Process* process) {
  Process::State state = process->state();
  if (state != Process::IDLE) {
    if (state == Process::SUSPENDED_IDLE) {
      process->set_state(Process::SUSPENDED_SCHEDULED);
    }
    return;
  }
  process->set_state(Process::SCHEDULED);

  uint8 priority = process->update_priority();
  ready_queue(priority).append(process);
  if (++ready_count_ == 1) {
    // Only signal if we added the first ready process.
    OS::signal(has_processes_);
  }

  wake_worker_for_ready_process(locker, priority);
}

void Scheduler::wake_worker_for_ready_process(Locker& locker, uint8 priority) {
  // Count the number of idle scheduler threads.
  int idle = 0;
  for (SchedulerThread* thread : threads_) {
    Process* process = thread->interpreter()->process();
    if (process) continue;
    if (++idle >= ready_count_) return;
  }

  // On some platforms, we can dynamically spin up another thread
  // to take care of the extra work.
  SchedulerThread* extra_thread = start_thread(locker);
  if (extra_thread) return;

  // TODO(kasper): Can we avoid preempting anything? If we know
  // that there are already enough processes marked for preemption
  // to satisfy all the more important ready processes, we don't
  // need more.

  // If all scheduler threads are busy running code, we preempt
  // the lowest priority process unless it is more important
  // than the process we're enqueuing.
  Process* lowest = null;
  uint8 lowest_priority = 0;
  for (SchedulerThread* thread : threads_) {
    // If the thread has already been picked to be preempted,
    // we choose another one.
    Process* process = thread->interpreter()->process();
    if (process == null || (process->signals() & Process::PREEMPT) != 0) continue;
    // If a process is external we cannot preempt it.
    if (process->program() == null) continue;
    // If we already have a better candidate, we skip this one.
    if (lowest && process->priority() >= lowest_priority) continue;
    lowest = process;
    lowest_priority = process->priority();
  }

  if (lowest && lowest_priority < priority) {
    lowest->signal(Process::PREEMPT);
  }
}

void Scheduler::terminate_execution(Locker& locker, ExitState exit) {
  if (!has_exit_reason()) {
    exit_state_ = exit;
  }

  for (SchedulerThread* thread : threads_) {
    Process* process = thread->interpreter()->process();
    if (process != null) {
      process->signal(Process::KILL);
    }
  }

  OS::signal(has_processes_);
}

void Scheduler::tick(Locker& locker, int64 now) {
  // A healthy CPU-bound process need not return to the scheduler. The tick
  // thread must keep platform watchdogs alive in that case as well.
  OS::feed_watchdog();
  tick_schedule(locker, now, true);

  int first_non_empty_ready_queue = NUMBER_OF_READY_QUEUES;
  for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
    if (ready_queue_[i].is_empty()) continue;
    first_non_empty_ready_queue = i;
    break;
  }

  bool any_profiling = num_profiled_processes_ > 0;
  bool any_ready = first_non_empty_ready_queue < NUMBER_OF_READY_QUEUES;
  if (!PROCESS_MAX_RUN_TIME_ENFORCE && !any_profiling && !any_ready &&
      num_run_time_limited_processes_ == 0) {
    return;
  }

  for (SchedulerThread* thread : threads_) {
    Process* process = thread->interpreter()->process();
    if (process == null) continue;

    int64 run_time_us = process->run_time_us(now);

    // Processes with a run-time limit or a CPU budget in their policy are
    // killed when they exceed it. For them this replaces the dead-lock FATAL
    // below, so a sandboxed process can't take down the VM.
    const PolicyQuotas& quotas = process->policy()->quotas();
    int64 max_run_time_us = quotas.max_run_time_us;
    int64 cpu_budget_us = quotas.cpu_budget_us;
    if (quotas.limits_run_time()) {
      bool over_run_time = max_run_time_us > 0 && run_time_us > max_run_time_us;
      bool over_budget = cpu_budget_us > 0 && process->cpu_time_us() + run_time_us > cpu_budget_us;
      if (over_run_time || over_budget) {
        process->kill_for_policy(SANDBOX_EXIT_CPU_BUDGET);
        continue;
      }
      if (process->signals() & Process::PREEMPT) continue;
      bool should_preempt =
           (max_run_time_us > 0 && run_time_us > max_run_time_us / 2)
        || (any_profiling && process->profiler() != null)
        || (any_ready && compute_ready_queue_index(process->priority()) >= first_non_empty_ready_queue);
      if (should_preempt) process->signal(Process::PREEMPT);
      continue;
    }

    if (!PROCESS_MAX_RUN_TIME_ENFORCE && !any_profiling && !any_ready) continue;

    // A primitive that runs long but reports progress (Process::note_progress,
    // install-time verification) is not a dead-lock.
    if (PROCESS_MAX_RUN_TIME_ENFORCE && process->stalled_us(now) > PROCESS_MAX_RUN_TIME_US) {
      fprintf(stderr, "Potential deadlock detected:\n");
      fprintf(stderr, "  Process: %d\n", process->id());
      uint8* current_bcp = process->current_bcp();
      Program* program = process->program();  // External processes have null programs.
      if (program) {
        const uint8* uuid = program->id();
        char uuid_buffer[37];
        snprintf(uuid_buffer, sizeof(uuid_buffer), "%08x-%04x-%04x-%04x-%04x%08x",
            static_cast<int>(Utils::read_unaligned_uint32_be(uuid)),
            static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 4)),
            static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 6)),
            static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 8)),
            static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 10)),
            static_cast<int>(Utils::read_unaligned_uint32_be(uuid + 12)));
        fprintf(stderr, "  Program: %s\n", uuid_buffer);

        if (program->is_valid_bcp(current_bcp)) {
          int bci = program->absolute_bci_from_bcp(current_bcp);
          fprintf(stderr, "  BCI: 0x%x\n", bci);

          Opcode opcode = static_cast<Opcode>(*current_bcp);
          if (opcode == Opcode::PRIMITIVE) {
            int module = current_bcp[1];
            int index = Utils::read_unaligned_uint16(current_bcp + 2);
            fprintf(stderr, "  Primitive: %d:%d\n", module, index);
          } else if (opcode == Opcode::ALLOCATE) {
            fprintf(stderr, "  Allocate: %d\n", current_bcp[1]);
          } else if (opcode == Opcode::ALLOCATE_WIDE) {
            fprintf(stderr, "  Allocate: %d\n", Utils::read_unaligned_uint16(current_bcp + 1));
          }
        }
        FATAL("Potential dead-lock");
      }
      FATAL("Potential dead-lock detected in process %d\n", process->id());
    }

    if (process->signals() & Process::PREEMPT) continue;
    bool should_preempt =
         (PROCESS_MAX_RUN_TIME_ENFORCE && run_time_us > PROCESS_MAX_RUN_TIME_US / 2)
      || (any_profiling && process->profiler() != null)
      || (any_ready && compute_ready_queue_index(process->priority()) >= first_non_empty_ready_queue);
    if (should_preempt) process->signal(Process::PREEMPT);
  }
}

void Scheduler::tick_schedule(Locker& locker, int64 now, bool reschedule) {
  int period = (num_profiled_processes_ > 0)
      ? TICK_PERIOD_PROFILING_US
      : TICK_PERIOD_US;
  int64 next = now + period;
  if (!reschedule && next >= tick_next()) return;
  next_tick_ = next;
  if (!reschedule) OS::signal(has_threads_);
}

void Scheduler::notify_profiler(int change) {
  Locker locker(mutex_);
  notify_profiler(locker, change);
}

void Scheduler::notify_profiler(Locker& locker, int change) {
  num_profiled_processes_ += change;
  tick_schedule(locker, OS::get_monotonic_time(), false);
}

Process* Scheduler::find_process(Locker& locker, int pid) {
  for (ProcessGroup* group : groups_) {
    Process* p = group->lookup(pid);
    if (p != null) return p;
  }
  return null;
}

namespace {

struct ProcessChunkWalk {
  void* context;
  Scheduler::ProcessChunkCallback* callback;
  const Scheduler::ProcessChunkOwner* owner;
};

void forward_process_chunk(void* context, Process* process, uword address, uword size) {
  auto walk = static_cast<ProcessChunkWalk*>(context);
  walk->callback(walk->context, walk->owner, address, size);
}

}  // namespace

void Scheduler::iterate_process_chunks(void* context, ProcessChunkCallback* callback) {
  Locker locker(mutex_);
  for (ProcessGroup* group : groups_) {
    ProcessListFromProcessGroup& processes = group->processes();
    for (auto it : processes) {
      Program* program = it->program();
      if (program == null) continue;  // External process.
      // The processes in the groups' lists are alive while the lock is held
      // (begin_process_teardown unlinks a process before it is deleted).
      ProcessChunkOwner owner;
      owner.pid = it->id();
      owner.is_boot_process = it == boot_process_;
      memcpy(owner.program_id, program->id(), UUID_SIZE);
      ProcessChunkWalk walk = { context, callback, &owner };
      it->object_heap()->iterate_chunks(&walk, forward_process_chunk);
    }
  }
}

} // namespace toit

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
  MessageEncoder::encode_process_message(data, 0);

  SystemMessage* result = _new SystemMessage(type, gid, -1, data);
  if (result == NULL) {
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

  ProcessGroup* group = ProcessGroup::create(group_id, program);
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group_id);
  Object** global_variables = program->global_variables.copy();
  ASSERT(global_variables);  // Booting system.
  Process* process = _new Process(program, group, termination, manager.initial_chunk, global_variables);
  ASSERT(process);
  manager.dont_auto_free();
  // Start the boot process with a high priority. It can always
  // be adjusted later if necessary.
  update_priority(locker, process, Process::PRIORITY_HIGH);
  return process;
}

#ifdef TOIT_FREERTOS

Scheduler::ExitState Scheduler::run_boot_program(Program* program, int group_id) {
  Locker locker(mutex_);
  Process* process = new_boot_process(locker, program, group_id);
  return launch_program(locker, process);
}

#else

Scheduler::ExitState Scheduler::run_boot_program(Program* program, char** argv, int group_id) {
  Locker locker(mutex_);
  Process* process = new_boot_process(locker, program, group_id);
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
  process->mark_as_priviliged();
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

int Scheduler::run_program(Program* program, uint8* arguments, ProcessGroup* group, Chunk* initial_chunk, Object** global_variables) {
  Locker locker(mutex_);
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group->id());
  if (termination == null) {
    return INVALID_PROCESS_ID;
  }
  Process* process = _new Process(program, group, termination, initial_chunk, global_variables);
  if (process == null) {
    delete termination;
    return INVALID_PROCESS_ID;
  }
  process->set_main_arguments(arguments);

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
  ProcessGroup* group = ProcessGroup::create(group_id, null);
  if (group == null) return null;
  SystemMessage* termination =  new_process_message(SystemMessage::TERMINATED, group_id);
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
  add_process(locker, process);
  return process;
}

scheduler_err_t Scheduler::send_system_message(SystemMessage* message) {
  Locker locker(mutex_);
  return send_system_message(locker, message);
}

scheduler_err_t Scheduler::send_message(ProcessGroup* group, int process_id, Message* message) {
  Locker locker(mutex_);
  Process* p = group->lookup(process_id);
  if (p == null) return MESSAGE_NO_SUCH_RECEIVER;
  p->_append_message(message);
  process_ready(locker, p);
  return MESSAGE_OK;
}

scheduler_err_t Scheduler::send_message(int process_id, Message* message) {
  Locker locker(mutex_);
  Process* p = find_process(locker, process_id);
  if (p == null) return MESSAGE_NO_SUCH_RECEIVER;
  p->_append_message(message);
  process_ready(locker, p);
  return MESSAGE_OK;
}

scheduler_err_t Scheduler::send_system_message(Locker& locker, SystemMessage* message) {
  if (boot_process_ != null) {
    boot_process_->_append_message(message);
    process_ready(locker, boot_process_);
    return MESSAGE_OK;
  }

  // Default processing of system messages.
  switch (message->type()) {
    case SystemMessage::TERMINATED:
      int value;
      if (MessageDecoder::decode_process_message(message->data(), &value)) {
        ExitReason reason = (value == 0) ? EXIT_DONE : EXIT_ERROR;
        terminate_execution(locker, ExitState(reason, value));
      }
      break;
    case SystemMessage::SPAWNED: {
      // Do nothing. With no boot process, we don't care about newly spawned processes.
      break;
    }
    default:
      FATAL("unhandled system message %d", message->type());
  }

  delete message;
  return MESSAGE_OK;
}

void Scheduler::send_notify_message(ObjectNotifier* notifier) {
  Locker locker(mutex_);
  Process* process = notifier->process();
  if (process->state() == Process::TERMINATING) return;
  process->_append_message(notifier->message());
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
                     Method method, uint8* arguments, Chunk* initial_chunk, Object** global_variables) {
  Locker locker(mutex_);

  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, process_group->id());
  if (!termination) return INVALID_PROCESS_ID;

  Process* process = _new Process(program, process_group, termination, method, initial_chunk, global_variables);
  if (!process) {
    delete termination;
    return INVALID_PROCESS_ID;
  }
  process->set_spawn_arguments(arguments);

  SystemMessage* spawned = new_process_message(SystemMessage::SPAWNED, process_group->id());
  if (!spawned) {
    delete termination;
    delete process;
    return INVALID_PROCESS_ID;
  }
  int pid = process->id();
  spawned->set_pid(pid);
  // Send the SPAWNED message before returning from the call to spawn. This is necessary
  // to make sure the system doesn't conclude that there are no processes left just after
  // spawning, but before the spawned process starts up.
  send_system_message(locker, spawned);
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
  if (next_process_id_ == INVALID_PROCESS_ID) next_process_id_++;
  return next_process_id_++;
}

int Scheduler::process_count() {
  Locker locker(mutex_);
  return num_processes_;
}

void Scheduler::run(SchedulerThread* scheduler_thread) {
  Locker locker(mutex_);

  // Once started, a SchedulerThread continues to run until the whole system
  // is shutting down with an exit reason. This makes it possible to preallocate
  // all OS threads at startup on platforms that may have a hard time starting
  // such threads later due to memory pressure.
  while (!has_exit_reason()) {
    if (!has_ready_processes(locker)) {
      OS::wait(has_processes_);
      continue;
    }

    Process* process = null;
    for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
      ProcessListFromScheduler& ready_queue = ready_queue_[i];
      if (ready_queue.is_empty()) continue;
      process = ready_queue.remove_first();
      break;
    }
    ASSERT(process->state() == Process::SCHEDULED);

    if (has_ready_processes(locker)) {
      // Notify potential other thread that there are more processes ready.
      OS::signal(has_processes_);
    }

    run_process(locker, process, scheduler_thread);
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
  bool doing_idle_process_gc = try_hard || malloc_failed || (process && process->system_refused_memory());
  bool doing_cross_process_gc = false;
  uint64 start = OS::get_monotonic_time();
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
      gc_waiting_for_preemption_ = 0;

      for (SchedulerThread* thread : threads_) {
        Process* running_process = thread->interpreter()->process();
        if (running_process != null && running_process != process) {
          running_process->signal(Process::PREEMPT);
          gc_waiting_for_preemption_++;
        }
      }

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

  int gcs = 0;
  if (doing_idle_process_gc) {
    ProcessListFromScheduler targets;
    { Locker locker(mutex_);
      for (ProcessGroup* group : groups_) {
        for (Process* target : group->processes()) {
          if (target->program() == null) continue;  // External process.
          if (target->state() != Process::RUNNING && !target->idle_since_gc()) {
            if (target->state() != Process::SUSPENDED_AWAITING_GC) {
              gc_suspend_process(locker, target);
            }
            targets.append(target);
          }
        }
      }
    }

    for (Process* target : targets) {
      GcType type = target->gc(try_hard);
      if (type != NEW_SPACE_GC) {
        Locker locker(mutex_);
        target->set_idle_since_gc(true);
      }
      gcs++;
    }

    { Locker locker(mutex_);
      while (!targets.is_empty()) {
        Process* target = targets.remove_first();
        if (target->state() != Process::SUSPENDED_AWAITING_GC) {
          gc_resume_process(locker, target);
        }
      }
    }
  }

  if (process && process->program() != null) {
    // Not external process.
    process->gc(try_hard);
  }

  if (doing_cross_process_gc) {
    Locker locker(mutex_);
    gc_cross_processes_ = false;
#ifdef TOIT_GC_LOGGING
    int64 microseconds = OS::get_monotonic_time() - start;
    printf("[gc @ %p%s | cross process gc with %d gcs, took %d.%03dms]\n",
        process, VM::current()->scheduler()->is_boot_process(process) ? "*" : " ",
        gcs + 1,
        static_cast<int>(microseconds / 1000),
        static_cast<int>(microseconds % 1000));
#endif
    OS::signal_all(gc_condition_);
  }
}

void Scheduler::add_process(Locker& locker, Process* process) {
  num_processes_++;
  process_ready(locker, process);
}

Object* Scheduler::process_stats(Array* array, int group_id, int process_id, Process* calling_process) {
  Locker locker(mutex_);
  ProcessGroup* group = null;
  for (auto g : groups_) {
    if (g->id() == group_id) group = g;
  }
  if (group == null) return calling_process->program()->null_object();
  Process* subject_process = group->lookup(process_id);
  if (subject_process == null) return calling_process->program()->null_object();  // Process not found.
  uword length = array->length();
#ifdef TOIT_FREERTOS
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
  scheduler_thread->unpin();

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
      Unlocker unlock(locker);
      result = interpreter->run();
    }
    preemption_method_header_bcp = interpreter->preemption_method_header_bcp();
    interpreter->deactivate();

    if (process->profiler() && process->profiler()->is_active()) {
      notify_profiler(locker, -1);
    }
  } else if (process->signals() == 0) {
    ASSERT(process->idle_since_gc());
    Unlocker unlock(locker);
    result = runner->run();
  }

  process->set_scheduler_thread(null);

  while (result.state() != Interpreter::Result::TERMINATED) {
    uint32_t signals = process->signals();
    if (signals == 0) break;
    if (signals & Process::KILL) {
      result = Interpreter::Result(Interpreter::Result::TERMINATED);
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
      Profiler* profiler = process->profiler();
      Task* task = process->task();
      if (profiler && task && profiler->should_profile_task(task->id())) {
        Stack* stack = task->stack();
        if (stack) {
          int bci = stack->absolute_bci_at_preemption(process->program());
          ASSERT(preemption_method_header_bcp);
          if (bci >= 0 && preemption_method_header_bcp) {
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
      wait_for_any_gc_to_complete(locker, process, Process::IDLE);
      if (process->has_messages()) {
        process_ready(locker, process);
      }
      break;

    case Interpreter::Result::TERMINATED: {
      wait_for_any_gc_to_complete(locker, process, Process::RUNNING);

      ProcessGroup* group = process->group();
      bool last_in_group = !group->remove(process);
      ASSERT(group->lookup(process->id()) == null);
      SystemMessage* message = process->take_termination_message(result.value());

      // Deleting processes might need to take the event source lock, so we have
      // to unlock the scheduler to not get into a deadlock with the delivery of
      // an asynchronous event that needs to call [process_ready] and thus also
      // take the scheduler lock.
      { Unlocker unlock(locker);
        delete process;
      }

      num_processes_--;
      if (process == boot_process_) boot_process_ = null;

      // Send the termination message after having deleted the process. This ensures
      // that the message for the boot process will not be assumed to be handled by
      // the boot process that is going away.
      if (send_system_message(locker, message) != MESSAGE_OK) {
#ifdef TOIT_FREERTOS
        printf("[message: cannot send termination message for pid %d]\n", process->id());
#endif
        delete message;
      }

      if (last_in_group) {
        group->unlink();
        delete group;
      }
      break;
    }

    case Interpreter::Result::DEEP_SLEEP: {
      ExitState exit(EXIT_DEEP_SLEEP, result.value());
      terminate_execution(locker, exit);
      break;
    }
  }
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
    process->set_state(Process::IDLE);
    process_ready(locker, process);
  }
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
  }
  ASSERT(process->is_suspended());
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
    gc_waiting_for_preemption_--;
    OS::signal_all(gc_condition_);
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
  USE(locker);  // We assume we own the mutex here.

  Process::State state = process->state();
  if (state != Process::IDLE) {
    if (state == Process::SUSPENDED_IDLE) {
      process->set_state(Process::SUSPENDED_SCHEDULED);
    }
    return;
  }
  process->set_state(Process::SCHEDULED);

  if (!has_ready_processes(locker)) {
    OS::signal(has_processes_);
  }

  uint8 priority = process->update_priority();
  ready_queue(priority).append(process);

  // If all scheduler threads are busy running code, we preempt
  // the lowest priority process unless it is more important
  // than the process we're enqueuing.
  Process* lowest = null;
  uint8 lowest_priority = 0;
  SchedulerThread* lowest_thread = null;
  for (SchedulerThread* thread : threads_) {
    // If the thread has already been picked to be preempted,
    // we choose another one.
    if (thread->is_pinned()) continue;
    Process* process = thread->interpreter()->process();
    if (process == null) {
      // We have found a thread that is ready to pick up
      // work. We pin it, so we don't pick this again before
      // it has had the chance to work.
      thread->pin();
      return;
    }
    // If a process is external we cannot preempt it.
    if (process->program() == null) continue;
    // If we already have a better candidate, we skip this one.
    if (lowest && process->priority() >= lowest_priority) continue;
    lowest = process;
    lowest_priority = process->priority();
    lowest_thread = thread;
  }
  // On some platforms, we can dynamically spin up another thread
  // to take care of the extra work.
  SchedulerThread* extra_thread = start_thread(locker);
  if (extra_thread) {
    extra_thread->pin();
  } else if (lowest && lowest_priority < priority) {
    lowest_thread->pin();
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
  tick_schedule(locker, now, true);

  int first_non_empty_ready_queue = -1;
  for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
    if (ready_queue_[i].is_empty()) continue;
    first_non_empty_ready_queue = i;
    break;
  }

  bool any_profiling = num_profiled_processes_ > 0;
  if (!any_profiling && first_non_empty_ready_queue < 0) {
    // No need to do preemption when there are no active profilers
    // and no other processes ready to run.
    return;
  }

  for (SchedulerThread* thread : threads_) {
    Process* process = thread->interpreter()->process();
    if (process == null) continue;
    int ready_queue_index = compute_ready_queue_index(process->priority());
    bool is_profiling = any_profiling && process->profiler() != null;
    if (is_profiling || ready_queue_index >= first_non_empty_ready_queue) {
      process->signal(Process::PREEMPT);
    }
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

bool Scheduler::has_ready_processes(Locker& locker) {
  for (int i = 0; i < NUMBER_OF_READY_QUEUES; i++) {
    if (!ready_queue_[i].is_empty()) return true;
  }
  return false;
}

} // namespace toit

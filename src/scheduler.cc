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
  _scheduler->run(this);
}

Scheduler::Scheduler()
    : _mutex(OS::allocate_mutex(2, "Scheduler"))
    , _has_processes(OS::allocate_condition_variable(_mutex))
    , _has_threads(OS::allocate_condition_variable(_mutex))
    , _gc_condition(OS::allocate_condition_variable(_mutex))
    , _gc_cross_processes(false)
    , _gc_waiting_for_preemption(0)
    , _num_processes(0)
    , _next_group_id(0)
    , _next_process_id(0)
    , _num_threads(0)
    , _max_threads(OS::num_cores())
    , _boot_process(null) {
  Locker locker(_mutex);
#ifdef TOIT_FREERTOS
  // On FreeRTOS we immediately start two threads (the main one and a second
  // one for the second core) because we don't want to handle allocation
  // failures when trying to start them later.
  while (_num_threads < _max_threads) {
    start_thread(locker, EVEN_IF_PROCESSES_NOT_READY);
  }
#endif
}

Scheduler::~Scheduler() {
  ASSERT(_groups.is_empty());
  ASSERT(_ready_processes.is_empty());
  ASSERT(_threads.is_empty());
  OS::dispose(_gc_condition);
  OS::dispose(_has_threads);
  OS::dispose(_has_processes);
  OS::dispose(_mutex);
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

Scheduler::ExitState Scheduler::run_boot_program(Program* program, char** arguments, int group_id) {
  // Allocation takes the memory lock which must happen before taking the scheduler lock.
  InitialMemoryManager manager;
  bool ok = manager.allocate();
  USE(ok);
  // We assume that allocate_initial_block succeeds since we can't run out of
  // memory while booting.
  ASSERT(ok);
  Locker locker(_mutex);
  ProcessGroup* group = ProcessGroup::create(group_id, program);
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group_id);
  Process* process = _new Process(program, group, termination, manager.initial_chunk);
  ASSERT(process);
  process->set_main_arguments(arguments);
  manager.dont_auto_free();
  return launch_program(locker, process);
}

#ifndef TOIT_FREERTOS
Scheduler::ExitState Scheduler::run_boot_program(
    Program* boot_program,
    SnapshotBundle system,
    SnapshotBundle application,
    char** arguments,
    int group_id) {
  ProcessGroup* group = ProcessGroup::create(group_id, boot_program);
  // Allocation takes the memory lock which must happen before taking the scheduler lock.
  InitialMemoryManager manager;
  bool ok = manager.allocate();
  USE(ok);
  // We assume that allocate_initial_block succeeds since we can't run out of
  // memory while booting.
  ASSERT(ok);
  Locker locker(_mutex);
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group_id);
  Process* process = _new Process(boot_program, group, termination, manager.initial_chunk);
  ASSERT(process);
  process->set_main_arguments(arguments);
  process->set_spawn_arguments(system, application);
  manager.dont_auto_free();
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
  ASSERT(_boot_process == null);
  _groups.prepend(group);
  _boot_process = process;
  add_process(locker, process);

  tick_schedule(locker, OS::get_monotonic_time(), true);
  while (_num_processes > 0 && _num_threads > 0) {
    int64 time = OS::get_monotonic_time();
    int64 next = tick_next();
    if (time >= next) {
      tick(locker, time);
    } else {
      int64 delay_us = next - time;
      OS::wait_us(_has_threads, delay_us);
    }
  }

  if (!has_exit_reason()) {
    _exit_state.reason = EXIT_DONE;
  }

  while (SchedulerThread* thread = _threads.remove_first()) {
    Unlocker unlock(locker);
    thread->join();
    delete thread;
  }

  while (_ready_processes.remove_first()) {
    // Clear out the list of ready processes, so we don't have any dangling
    // pointers to processes that we delete in a moment.
  }

  while (ProcessGroup* group = _groups.remove_first()) {
    while (Process* process = group->processes().remove_first()) {
      Unlocker unlock(locker);
      // TODO(kasper): We should let any ExternalSystemMessageHandler know that
      // their process has been deleted.
      delete process;
    }
    delete group;
  }

  return _exit_state;
}

int Scheduler::next_group_id() {
  Locker locker(_mutex);
  return _next_group_id++;
}

int Scheduler::run_program(Program* program, char** arguments, ProcessGroup* group, Chunk* initial_chunk) {
  Locker locker(_mutex);
  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, group->id());
  if (termination == null) {
    return INVALID_PROCESS_ID;
  }
  Process* process = _new Process(program, group, termination, initial_chunk);
  if (process == null) {
    delete termination;
    return INVALID_PROCESS_ID;
  }
  process->set_main_arguments(arguments);

  Interpreter interpreter;
  interpreter.activate(process);
  interpreter.prepare_process();
  interpreter.deactivate();

  _groups.append(group);
  add_process(locker, process);
  return process->id();
}

Process* Scheduler::run_external(ProcessRunner* runner) {
  int group_id = next_group_id();
  Locker locker(_mutex);
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
  _groups.append(group);
  add_process(locker, process);
  return process;
}

scheduler_err_t Scheduler::send_system_message(SystemMessage* message) {
  Locker locker(_mutex);
  return send_system_message(locker, message);
}

scheduler_err_t Scheduler::send_message(ProcessGroup* group, int process_id, Message* message) {
  Locker locker(_mutex);
  Process* p = group->lookup(process_id);
  if (p == null) return MESSAGE_NO_SUCH_RECEIVER;
  p->_append_message(message);
  process_ready(locker, p);
  return MESSAGE_OK;
}

scheduler_err_t Scheduler::send_message(int process_id, Message* message) {
  Locker locker(_mutex);
  Process* p = find_process(locker, process_id);
  if (p == null) return MESSAGE_NO_SUCH_RECEIVER;
  p->_append_message(message);
  process_ready(locker, p);
  return MESSAGE_OK;
}

scheduler_err_t Scheduler::send_system_message(Locker& locker, SystemMessage* message) {
  if (_boot_process != null) {
    _boot_process->_append_message(message);
    process_ready(locker, _boot_process);
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
  Locker locker(_mutex);
  Process* process = notifier->process();
  if (process->state() == Process::TERMINATING) return;
  process->_append_message(notifier->message());
  process_ready(locker, process);
}

bool Scheduler::signal_process(Process* sender, int target_id, Process::Signal signal) {
  if (sender != _boot_process) return false;

  Locker locker(_mutex);
  Process* target = find_process(locker, target_id);
  if (target == null) return false;

  target->signal(signal);
  process_ready(locker, target);
  return true;
}

Process* Scheduler::spawn(Program* program, ProcessGroup* process_group, Method method, uint8* arguments, Chunk* initial_chunk) {
  Locker locker(_mutex);

  SystemMessage* termination = new_process_message(SystemMessage::TERMINATED, process_group->id());
  if (!termination) return null;

  Process* process = _new Process(program, process_group, termination, method, initial_chunk);
  if (!process) {
    delete termination;
    return null;
  }
  process->set_spawn_arguments(arguments);

  SystemMessage* spawned = new_process_message(SystemMessage::SPAWNED, process_group->id());
  if (!spawned) {
    delete termination;
    delete process;
    return null;
  }
  spawned->set_pid(process->id());
  // Send the SPAWNED message before returning from the call to spawn. This is necessary
  // to make sure the system doesn't conclude that there are no processes left just after
  // spawning, but before the spawned process starts up.
  send_system_message(locker, spawned);
  new_process(locker, process);
  return process;
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
  if (_next_process_id == INVALID_PROCESS_ID) _next_process_id++;
  return _next_process_id++;
}

int Scheduler::process_count() {
  Locker locker(_mutex);
  return _num_processes;
}

void Scheduler::run(SchedulerThread* scheduler_thread) {
  Locker locker(_mutex);

  // Once started, a SchedulerThread continues to run until the whole system
  // is shutting down with an exit reason. This makes it possible to preallocate
  // all OS threads at startup on platforms that may have a hard time starting
  // such threads later due to memory pressure.
  while (!has_exit_reason()) {
    if (_ready_processes.is_empty()) {
      OS::wait(_has_processes);
      continue;
    }

    Process* process = _ready_processes.remove_first();
    ASSERT(process->state() == Process::SCHEDULED);

    if (!_ready_processes.is_empty()) {
      // Notify potential other thread that there are more processes ready.
      OS::signal(_has_processes);
    }

    run_process(locker, process, scheduler_thread);
  }

  // Notify potential other thread, that no more processes are left.
  OS::signal(_has_processes);

  _num_threads--;

  OS::signal(_has_threads);
}

bool Scheduler::is_running(const Program* program) {
  Locker locker(_mutex);
  for (ProcessGroup* group : _groups) {
    if (group->program() == program) {
      return true;
    }
  }
  return false;
}

bool Scheduler::kill(const Program* program) {
  Locker locker(_mutex);
  for (ProcessGroup* group : _groups) {
    if (group->program() != program) continue;
    for (Process* p : group->_processes) {
      p->signal(Process::KILL);
      process_ready(locker, p);
    }
    return true;
  }
  return false;
}

void Scheduler::gc(Process* process, bool malloc_failed, bool try_hard) {
  bool doing_idle_process_gc = try_hard || malloc_failed || process->system_refused_memory();
  bool doing_cross_process_gc = false;
  uint64 start = OS::get_monotonic_time();

  if (try_hard) {
    Locker locker(_mutex);
    if (_gc_cross_processes) {
      doing_idle_process_gc = false;
    } else {
      doing_cross_process_gc = true;
      _gc_cross_processes = true;
      _gc_waiting_for_preemption = 0;

      for (SchedulerThread* thread : _threads) {
        Process* running_process = thread->interpreter()->process();
        if (running_process != null && running_process != process) {
          running_process->signal(Process::PREEMPT);
          _gc_waiting_for_preemption++;
        }
      }

      // We try to get the processes currently running on the OS threads
      // to be preempted, but since we only GC them if we can get them to
      // be "suspendable" or "suspended" later, we can live with this
      // timing out and not succeeding.
      int64 deadline = start + 1000000LL;  // Wait for up to 1 second.
      while (_gc_waiting_for_preemption > 0) {
        if (!OS::wait_us(_gc_condition, deadline - OS::get_monotonic_time())) {
#ifdef TOIT_GC_LOGGING
          printf("[gc @ %p%s | timed out waiting for %d processes to stop]\n",
              process, VM::current()->scheduler()->is_boot_process(process) ? "*" : " ",
              _gc_waiting_for_preemption);
#endif
          _gc_waiting_for_preemption = 0;
        }
      }
    }
  }

  int gcs = 0;
  if (doing_idle_process_gc) {
    ProcessListFromScheduler targets;
    { Locker locker(_mutex);
      for (ProcessGroup* group : _groups) {
        bool done = false;
        for (Process* target : group->processes()) {
          if (target->state() != Process::RUNNING && !target->idle_since_gc()) {
            if (target->state() != Process::SUSPENDED_AWAITING_GC) {
              gc_suspend_process(locker, target);
            }
            target->set_idle_since_gc(true);  // Will be true in a little while.
            targets.append(target);
            if (!try_hard) {
              done = true;
              break;
            }
          }
        }
        if (done) break;
      }
    }

    for (Process* target : targets) {
      target->gc(try_hard);
      gcs++;
    }

    { Locker locker(_mutex);
      while (!targets.is_empty()) {
        Process* target = targets.remove_first();
        if (target->state() != Process::SUSPENDED_AWAITING_GC) {
          gc_resume_process(locker, target);
        }
      }
    }
  }

  process->gc(try_hard);

  if (doing_cross_process_gc) {
    Locker locker(_mutex);
    _gc_cross_processes = false;
#ifdef TOIT_GC_LOGGING
    int64 microseconds = OS::get_monotonic_time() - start;
    printf("[gc @ %p%s | cross process gc with %d gcs, took %d.%03dms]\n",
        process, VM::current()->scheduler()->is_boot_process(process) ? "*" : " ",
        gcs + 1,
        static_cast<int>(microseconds / 1000),
        static_cast<int>(microseconds % 1000));
#endif
    OS::signal_all(_gc_condition);
  }
}

void Scheduler::add_process(Locker& locker, Process* process) {
  _num_processes++;
  process_ready(locker, process);
  start_thread(locker, ONLY_IF_PROCESSES_ARE_READY);
}

Object* Scheduler::process_stats(Array* array, int group_id, int process_id, Process* calling_process) {
  Locker locker(_mutex);
  ProcessGroup* group = null;
  for (auto g : _groups) {
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
    case 10:
      array->at_put(9, Smi::from(subject_process->gc_count(FULL_GC)));
    case 9:
      array->at_put(8, Smi::from(Utils::min(max, info.largest_free_block)));
    case 8:
      array->at_put(7, Smi::from(Utils::min(max, info.total_free_bytes)));
    case 7:
      array->at_put(6, Smi::from(process_id));
    case 6:
      array->at_put(5, Smi::from(group_id));
    case 5: {
      Object* total = Primitive::integer(subject_process->object_heap()->total_bytes_allocated(), calling_process);
      if (Primitive::is_error(total)) return total;
      array->at_put(4, total);
    }
    case 4:
      array->at_put(3, Smi::from(subject_process->message_count()));
    case 3:
      array->at_put(2, Smi::from(subject_process->object_heap()->bytes_reserved()));
    case 2:
      array->at_put(1, Smi::from(subject_process->object_heap()->bytes_allocated()));
    case 1:
      array->at_put(0, Smi::from(subject_process->gc_count(NEW_SPACE_GC)));
    case 0:
      (void)0;  // Do nothing.
  }
  return array;
}

void Scheduler::run_process(Locker& locker, Process* process, SchedulerThread* scheduler_thread) {
  wait_for_any_gc_to_complete(locker, process, Process::RUNNING);
  process->set_scheduler_thread(scheduler_thread);

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

      _num_processes--;
      if (process == _boot_process) _boot_process = null;

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

void Scheduler::gc_suspend_process(Locker& locker, Process* process) {
  ASSERT(process->state() != Process::RUNNING);  // Preempt the process first.
  ASSERT(process->state() != Process::SUSPENDED_AWAITING_GC);
  ASSERT(!process->is_suspended());
  if (process->state() == Process::IDLE) {
    process->set_state(Process::SUSPENDED_IDLE);
  } else if (process->state() == Process::SCHEDULED) {
    process->set_state(Process::SUSPENDED_SCHEDULED);
    _ready_processes.remove(process);
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
  if (_gc_cross_processes) {
    process->set_state(Process::SUSPENDED_AWAITING_GC);
    _gc_waiting_for_preemption--;
    OS::signal_all(_gc_condition);
    do {
      OS::wait(_gc_condition);
    } while (_gc_cross_processes);
  }
  process->set_state(new_state);
}

void Scheduler::start_thread(Locker& locker, StartThreadRule force) {
  if (force == ONLY_IF_PROCESSES_ARE_READY && _ready_processes.is_empty()) return;
  if (_num_threads == _max_threads) return;

  SchedulerThread* new_thread = _new SchedulerThread(this);
  // On FreeRTOS we start both threads at boot time with the
  // EVEN_IF_PROCESSES_NOT_READY flag and then don't start other
  // threads. This should be enough, and should ensure that allocation
  // does not fail. On other platforms we assume that allocation will
  // not fail.
#ifdef TOIT_FREERTOS
  ASSERT(force == EVEN_IF_PROCESSES_NOT_READY);
#endif
  if (new_thread == null) FATAL("OS thread spawn failed");
  int core = _num_threads++;
  _threads.prepend(new_thread);
  if (!new_thread->spawn(4 * KB, core)) FATAL("OS thread spawn failed");
}

void Scheduler::process_ready(Process* process) {
  Locker locker(_mutex);
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

  if (_ready_processes.is_empty()) {
    OS::signal(_has_processes);
  }
  _ready_processes.append(process);
}

void Scheduler::terminate_execution(Locker& locker, ExitState exit) {
  if (!has_exit_reason()) {
    _exit_state = exit;
  }

  for (SchedulerThread* thread : _threads) {
    Process* process = thread->interpreter()->process();
    if (process != null) {
      process->signal(Process::KILL);
    }
  }

  OS::signal(_has_processes);
}

void Scheduler::tick(Locker& locker, int64 now) {
  tick_schedule(locker, now, true);

  if (_num_profiled_processes == 0 && _ready_processes.is_empty()) {
    // No need to do preemption when there are no active profilers
    // and no other processes ready to run.
    return;
  }

  for (SchedulerThread* thread : _threads) {
    Process* process = thread->interpreter()->process();
    if (process != null) {
      process->signal(Process::PREEMPT);
    }
  }
}

void Scheduler::tick_schedule(Locker& locker, int64 now, bool reschedule) {
  int period = (_num_profiled_processes > 0)
      ? TICK_PERIOD_PROFILING_US
      : TICK_PERIOD_US;
  int64 next = now + period;
  if (!reschedule && next >= tick_next()) return;
  _next_tick = next;
  if (!reschedule) OS::signal(_has_threads);
}

void Scheduler::notify_profiler(int change) {
  Locker locker(_mutex);
  notify_profiler(locker, change);
}

void Scheduler::notify_profiler(Locker& locker, int change) {
  _num_profiled_processes += change;
  tick_schedule(locker, OS::get_monotonic_time(), false);
}

Process* Scheduler::find_process(Locker& locker, int process_id) {
  for (ProcessGroup* group : _groups) {
    Process* p = group->lookup(process_id);
    if (p != null) return p;
  }

  return null;
}

} // namespace toit

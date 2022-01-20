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

#ifdef TOIT_POSIX
void signal_handler(int sig) {
  signal(sig, SIG_IGN);
  toit::VM::current()->scheduler()->print_stack_traces();
  signal(SIGQUIT, signal_handler);
}
#endif

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

Scheduler::ExitState Scheduler::run_boot_program(Program* program, char** args, int group_id) {
  // We assume that allocate_initial_block succeeds since we can't run out of
  // memory while booting.
  // Allocation takes the memory lock which must happen before taking the scheduler lock.
  Block* initial_block = VM::current()->heap_memory()->allocate_initial_block();
  Locker locker(_mutex);
  ProcessGroup* group = ProcessGroup::create(group_id);
  return launch_program(locker, _new Process(program, group, args, initial_block));
}

#ifndef TOIT_FREERTOS
Scheduler::ExitState Scheduler::run_boot_program(
    Program* boot_program,
    SnapshotBundle application_bundle,
    char** args,
    int group_id) {
  ProcessGroup* group = ProcessGroup::create(group_id);
  // We assume that allocate_initial_block succeeds since we can't run out of
  // memory while booting.
  // Allocation takes the memory lock which must happen before taking the scheduler lock.
  Block* initial_block = VM::current()->heap_memory()->allocate_initial_block();
  Locker locker(_mutex);
  Process* process = _new Process(boot_program, group, application_bundle, args, initial_block);
  return launch_program(locker, process);
}
#endif

Scheduler::ExitState Scheduler::launch_program(Locker& locker, Process* process) {
  ProcessGroup* group = process->group();
  Interpreter interpreter;
  interpreter.activate(process);
  interpreter.prepare_process();
  interpreter.deactivate();
  ASSERT(process->is_privileged());

#ifdef TOIT_POSIX
  signal(SIGQUIT, signal_handler);
#endif

  // Update the state and start the boot process.
  ASSERT(/*_groups.is_empty() && */_boot_process == null);
  _groups.prepend(group);
  _boot_process = process;
  add_process(locker, process);

  int64 next_tick_time = OS::get_monotonic_time() + TICK_PERIOD_US;

  while (_num_processes > 0 && _num_threads > 0) {
    int64 time = OS::get_monotonic_time();
    if (time >= next_tick_time) {
      next_tick_time = time + Scheduler::TICK_PERIOD_US;
      tick(locker);
    }
    ASSERT(time < next_tick_time);
    int delay_ms = 1 + ((next_tick_time - time - 1) / 1000); // Ceiling division.

    OS::wait(_has_threads, delay_ms);
  }

  if (!has_exit_reason()) {
    _exit_state.reason = EXIT_DONE;
  }

  while (SchedulerThread* thread = _threads.remove_first()) {
    Unlocker unlock(locker);
    thread->join();
    delete thread;
  }

  while (ProcessGroup* group = _groups.remove_first()) {
    while (Process* process = group->processes().remove_first()) {
      Unlocker unlock(locker);
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

int Scheduler::run_program(Program* program, char** args, ProcessGroup* group, Block* initial_block) {
  Locker locker(_mutex);
  Process* process = _new Process(program, group, args, initial_block);
  if (process == null) return INVALID_PROCESS_ID;
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
  ProcessGroup* group = ProcessGroup::create(group_id);
  Process* process = _new Process(runner, group);
  if (process == null) return null;
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
      if (MessageDecoder::decode_termination_message(message->data(), &value)) {
        ExitReason reason = (value == 0) ? EXIT_DONE : EXIT_ERROR;
        terminate_execution(locker, ExitState(reason, value));
      }
      break;

    default:
      FATAL("unhandled system message %d", message->type());
  }

  delete message;
  return MESSAGE_OK;
}

bool Scheduler::signal_process(Process* sender, int target_id, Process::Signal signal) {
  Locker locker(_mutex);

  Process* target = sender->group()->lookup(target_id);

  if (target == null) return false;

  if (sender != _boot_process) return false;

  target->signal(signal);
  process_ready(locker, target);
  return true;
}

Process* Scheduler::hatch(Program* program, ProcessGroup* process_group, Method method, const uint8* array_address, int array_length, Block* initial_block) {
  Locker locker(_mutex);

  Process* process = _new Process(program, process_group, method, array_address, array_length, initial_block);
  if (!process) return null;

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

void Scheduler::scavenge(Process* process, bool malloc_failed, bool try_hard) {
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
      int64 deadline = start + 1000000;  // Wait for up to 1 second.
      while (_gc_waiting_for_preemption > 0) {
        int64 wait_ms = Utils::max(1LL, (deadline - OS::get_monotonic_time()) / 1000);
        if (!OS::wait(_gc_condition, wait_ms)) {
#ifdef TOIT_GC_LOGGING
          printf("[cross-process gc: timed out waiting for %d]\n", _gc_waiting_for_preemption);
#endif
          _gc_waiting_for_preemption = 0;
        }
      }
    }
  }

  int scavenges = 0;
  if (doing_idle_process_gc) {
    ProcessListFromScheduler targets;
    { Locker locker(_mutex);
      for (ProcessGroup* group : _groups) {
        bool done = false;
        for (Process* target : group->processes()) {
          if (target->state() != Process::RUNNING && !target->idle_since_scavenge()) {
            if (target->state() != Process::SUSPENDED_AWAITING_GC) {
              scavenge_suspend_process(locker, target);
            }
            target->set_idle_since_scavenge(true);  // Will be true in a little while.
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
      target->scavenge();
      scavenges++;
    }

    { Locker locker(_mutex);
      while (!targets.is_empty()) {
        Process* target = targets.remove_first();
        if (target->state() != Process::SUSPENDED_AWAITING_GC) {
          scavenge_resume_process(locker, target);
        }
      }
    }
  }

  process->scavenge();

  if (doing_cross_process_gc) {
    Locker locker(_mutex);
    _gc_cross_processes = false;
#ifdef TOIT_GC_LOGGING
    uint64 elapsed = OS::get_monotonic_time() - start;
    printf("[cross-process gc: %d scavenges, took %d.%03dms]\n",
        scavenges + 1, elapsed / 1000, elapsed % 1000);
#endif
    OS::signal_all(_gc_condition);
  }
}

void Scheduler::print_stack_traces() {
  Locker locker(_mutex);
  Interpreter interpreter;
  for (ProcessGroup* group : _groups) {
    for (Process* p : group->_processes) {
      if (p->scheduler_thread() != null) {
        p->signal(Process::PRINT_STACK_TRACE);
        continue;
      }
      interpreter.activate(p);
      print_process(locker, p, &interpreter);
      interpreter.deactivate();
    }
  }
}

void Scheduler::add_process(Locker& locker, Process* process) {
  _num_processes++;
  process_ready(locker, process);
  start_thread(locker, ONLY_IF_PROCESSES_ARE_READY);
}

bool Scheduler::process_stats(Array* array, int group_id, int process_id) {
  ASSERT(array->length() == 7);
  Locker locker(_mutex);
  ProcessGroup* group = null;
  for (auto g : _groups) {
    if (g->id() == group_id) group = g;
  }
  if (group == null) return false;  // Group not found.
  Process* process = group->lookup(process_id);
  if (process == null) return false;  // Process not found.
  array->at_put(0, Smi::from(process->gc_count()));
  array->at_put(1, Smi::from(process->usage()->allocated()));
  array->at_put(2, Smi::from(process->usage()->reserved()));
  array->at_put(3, Smi::from(process->message_count()));
  array->at_put(4, Smi::from(process->object_heap()->total_bytes_allocated()));
  array->at_put(5, Smi::from(group_id));
  array->at_put(6, Smi::from(process_id));
  return true;
}

void Scheduler::run_process(Locker& locker, Process* process, SchedulerThread* scheduler_thread) {
  wait_for_any_gc_to_complete(locker, process, Process::RUNNING);
  process->set_scheduler_thread(scheduler_thread);
  int64 start = OS::get_monotonic_time();
  process->set_last_run(start);

  ProcessRunner* runner = process->runner();
  bool interpreted = (runner == null);
  Interpreter::Result result(Interpreter::Result::PREEMPTED);
  if (interpreted) {
    Interpreter* interpreter = scheduler_thread->interpreter();
    interpreter->activate(process);
    process->set_idle_since_scavenge(false);
    if (process->signals() == 0) {
      Unlocker unlock(locker);
      result = interpreter->run();
    }
    // Handle stack trace printing while the interpreter is still activated.
    if (process->signals() & Process::PRINT_STACK_TRACE) {
      print_process(locker, process, interpreter);
      process->clear_signal(Process::PRINT_STACK_TRACE);
    }
    interpreter->deactivate();
  } else if (process->signals() == 0) {
    ASSERT(process->idle_since_scavenge());
    Unlocker unlock(locker);
    result = runner->run();
  }

  process->increment_unyielded_for(OS::get_monotonic_time() - start);
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
    } else if (signals & Process::PRINT_STACK_TRACE) {
      ASSERT(!interpreted);
      process->clear_signal(Process::PRINT_STACK_TRACE);
    } else if (signals & Process::WATCHDOG) {
      process->clear_signal(Process::WATCHDOG);
    } else {
      UNREACHABLE();
    }
  }

  switch (result.state()) {
    case Interpreter::Result::PREEMPTED:
      wait_for_any_gc_to_complete(locker, process, Process::IDLE);
      process_ready(locker, process);
      break;

    case Interpreter::Result::YIELDED:
      process->clear_unyielded_for();
      wait_for_any_gc_to_complete(locker, process, Process::IDLE);
      if (process->has_messages()) {
        process_ready(locker, process);
      }
      break;

    case Interpreter::Result::TERMINATED: {
      wait_for_any_gc_to_complete(locker, process, Process::RUNNING);

      // TODO: Take down process group on error, if more than one process exists.
      int pid = process->id();
      ProcessGroup* group = process->group();
      bool last_in_group = !group->remove(process);
      ASSERT(group->lookup(process->id()) == null);

      // Deleting processes might need to take the event source lock, so we have
      // to unlock the scheduler to not get into a deadlock with the delivery of
      // an asynchronous event that needs to call [process_ready] and thus also
      // take the scheduler lock.
      { Unlocker unlock(locker);
        delete process;
      }

      _num_processes--;
      if (process == _boot_process) _boot_process = null;

      if (last_in_group) {
        SystemMessage* message = group->take_termination_message(pid, result.value());
        group->unlink();
        delete group;
        if (send_system_message(locker, message) != MESSAGE_OK) {
#ifdef TOIT_FREERTOS
          printf("[message: cannot send termination message for pid %d]\n", pid);
#endif
          delete message;
        }
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

void Scheduler::scavenge_suspend_process(Locker& locker, Process* process) {
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

void Scheduler::scavenge_resume_process(Locker& locker, Process* process) {
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

void Scheduler::print_process(Locker& locker, Process* process, Interpreter* interpreter) {
 // TODO(Anders): Printing has been removed. Convert it when fixing "Put this back into effect".
#ifdef DEBUG
  const int BUFFER_LENGTH = 1000;
  char* buffer = unvoid_cast<char*>(malloc(BUFFER_LENGTH));
  BufferPrinter printer(process->program(), buffer, BUFFER_LENGTH);

  printer.printf("Process #%d (%s):\n", process->id(), Process::StateName[process->state()]);

  // TODO: Print all tasks.
  Task* task = process->task();
  printer.printf("- task #%d:\n", task->id());
#endif
  /*
  TODO: Put this back into effect - move out to Resource?
  for (EventSource* c = VM::current()->event_manager()->event_sources(); c != null; c = c->next()) {
    Locker locker(c->mutex());
    int i = 0;
    for (EventSource::Id* id = c->ids(); id != null; id = id->next) {
      if (id->module->process() == process) {
        if (i == 0) {
          printer.printf("* %s resources:\n", c->name());
        }
        printer.printf("  - 0x%x: state:0x%x notifier:%p\n", id->id, id->state, id->object_notifier);
        i++;
      }
    }
  }
  */
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

word Scheduler::largest_number_of_blocks_in_a_process() {
  Locker locker(_mutex);
  word largest = 0;
  for (ProcessGroup* group : _groups) {
    largest = Utils::max(largest, group->largest_number_of_blocks_in_a_process());
  }
  return largest;
}

void Scheduler::tick(Locker& locker) {
  int64 now = OS::get_monotonic_time();

  for (SchedulerThread* thread : _threads) {
    Process* process = thread->interpreter()->process();
    if (process == null) continue;
    if (process == _boot_process) continue;
    int64 runtime = process->current_run_duration(now);
    if (runtime > WATCHDOG_PERIOD_US) {
      process->signal(Process::WATCHDOG);
    }
  }

  if (_ready_processes.is_empty()) return;

  for (SchedulerThread* thread : _threads) {
    Process* process = thread->interpreter()->process();
    if (process != null) {
      process->signal(Process::PREEMPT);
    }
  }
}

Process* Scheduler::find_process(Locker& locker, int process_id) {
  for (ProcessGroup* group : _groups) {
    Process* p = group->lookup(process_id);
    if (p != null) return p;
  }

  return null;
}

} // namespace toit

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

#pragma once

#include "heap.h"
#include "linked.h"
#include "messaging.h"
#include "os.h"
#include "process.h"
#include "process_group.h"
#include "top.h"

namespace toit {

typedef LinkedList<SchedulerThread> SchedulerThreadList;

// Keep in sync with constants in messages.toit.
enum scheduler_err_t : int {
  MESSAGE_OK = 0,
  MESSAGE_NO_SUCH_RECEIVER = 1
};

class SchedulerThread : public Thread, public SchedulerThreadList::Element {
 public:
  explicit SchedulerThread(Scheduler* scheduler)
      : Thread("Toit")
      , _scheduler(scheduler) {}

  ~SchedulerThread() {}

  Interpreter* interpreter() { return &_interpreter; }

  void entry();

 private:
  Scheduler* const _scheduler;
  Interpreter _interpreter;
};

class Scheduler {
 public:
  enum ExitReason {
    EXIT_NONE,
    EXIT_DONE,
    EXIT_DEEP_SLEEP,
    EXIT_ERROR,
  };

  struct ExitState {
    ExitState() : reason(EXIT_NONE), value(0) {}
    explicit ExitState(ExitReason reason) : reason(reason), value(0) {}
    ExitState(ExitReason reason, int64 value) : reason(reason), value(value) {}

    ExitReason reason;
    int64 value;
  };

  Scheduler();
  ~Scheduler();

  // Run the boot program and wait for all processes to run to completion.
  ExitState run_boot_program(Program* program, char** args, int group_id);

#ifndef TOIT_FREERTOS
  // Run the boot program and wait for all processes to run to completion.
  ExitState run_boot_program(
    Program* boot_program,
    SnapshotBundle system,  // It is then the responsibility of the system process to launch the application.
    SnapshotBundle application,
    char** args,
    int group_id);
#endif  // TOIT_FREERTOS

  // Run a new program. Returns the process ID of the root process.
  int run_program(Program* program, char** args, ProcessGroup* group, Chunk* initial_chunk);

  // Run a new external program. Returns the process.
  Process* run_external(ProcessRunner* runner);

  // Send a system message. Returns an error code to signal whether the message was delivered.
  scheduler_err_t send_system_message(SystemMessage* message);

  // Send message to the process by id. Returns an error code to signal whether the message was delivered.
  scheduler_err_t send_message(ProcessGroup* group, int process_id, Message* message);

  // Send message to the process by id. Returns an error code to signal whether the message was delivered.
  scheduler_err_t send_message(int process_id, Message* message);

  // Send notify message.
  void send_notify_message(ObjectNotifier* notifier);

  // Send a signal to a target process. Returns true if sender was able to
  // deliver the signal.
  bool signal_process(Process* sender, int target_id, Process::Signal signal);

  Process* hatch(Program* program, ProcessGroup* process_group, Method method, uint8* arguments, Chunk* initial_chunk);

  // Returns a new process id (only called from Process constructor).
  int next_process_id();
  int next_group_id();

  // Returns the number of live processes.
  int process_count();

  // Run processes from the Scheduler, until all processes are complete.
  // This function should be run by all threads that should execute bytecode.
  void run(SchedulerThread* scheduler_thread);

  // Determine if a given program is still running.
  bool is_running(const Program* program);

  // Send a kill signal to all processes running the given program.
  bool kill(const Program* program);

  // Collects garbage from the given process or some of the non-running
  // processes in the system.
  void gc(Process* process, bool malloc_failed, bool try_hard);

  // Profiler support.
  void activate_profiler(Process* process) { notify_profiler(1); }
  void deactivate_profiler(Process* process) { notify_profiler(-1); }

  // Primitive support.

  // Fills in an array with stats for the process with the given ids.
  // Returns an exception if the process doesn't exist, the array otherwise.
  Object* process_stats(Array* array, int group_id, int process_id, Process* calling_process);

  static const int INVALID_PROCESS_ID = -1;

  bool is_locked() const { return OS::is_locked(_mutex); }
  bool is_boot_process(Process* process) const { return _boot_process == process; }

 private:
  // Introduce a new process to the Scheduler. The Scheduler will not terminate until
  // all processes has completed.
  void new_process(Locker& locker, Process* process);
  void add_process(Locker& locker, Process* process);
  void run_process(Locker& locker, Process* process, SchedulerThread* scheduler_thread);

  // Profiler support.
  void notify_profiler(int change);
  void notify_profiler(Locker& locker, int change);

  // Suspend/resume support for processes. Allows other threads to temporarily suspend
  // a process and remove it from the ready list (if it's not idle). Resuming a process
  // puts the threads back into its original state, modulo idle->scheduled transitions that
  // are still supported while the process is suspended.
  void gc_suspend_process(Locker& locker, Process* process);
  void gc_resume_process(Locker& locker, Process* process);

  // Check if a cross-process GC is in process and wait for it to complete if so. After
  // waiting transition to the new state.
  void wait_for_any_gc_to_complete(Locker& locker, Process* process, Process::State new_state);

  typedef enum {
    ONLY_IF_PROCESSES_ARE_READY,
    EVEN_IF_PROCESSES_NOT_READY
  } StartThreadRule;

  void start_thread(Locker& locker, StartThreadRule force);

  void process_ready(Process* process);
  void process_ready(Locker& locker, Process* process);

  bool has_exit_reason() { return _exit_state.reason != EXIT_NONE; }

  scheduler_err_t send_system_message(Locker& locker, SystemMessage* message);

  void terminate_execution(Locker& locker, ExitState exit);

  Scheduler::ExitState launch_program(Locker& locker, Process* process);

  Process* find_process(Locker& locker, int process_id);

  SystemMessage* new_process_message(SystemMessage::Type type, int gid);

  static const int TICK_PERIOD_US = 100 * 1000;          // 100 ms.
#ifdef TOIT_FREERTOS
  static const int TICK_PERIOD_PROFILING_US = 10 * 100;  // 10 ms.
#else
  static const int TICK_PERIOD_PROFILING_US = 500;       // 0.5 ms.
#endif

  // Called by the launch thread to signal that time has passed.
  // The tick is used to drive process preemption.
  void tick(Locker& locker, int64 now);
  void tick_schedule(Locker& locker, int64 now, bool reschedule);

  // Get the time for the next tick for process preemption.
  int64 tick_next() const { return _next_tick; }

  Mutex* _mutex;
  ConditionVariable* _has_processes;
  ConditionVariable* _has_threads;
  ExitState _exit_state;

  // Condition variable used for both _gc_cross_processes and _gc_waiting_for_preemption.
  ConditionVariable* _gc_condition;

  // Are we currently doing a cross-process GC?
  bool _gc_cross_processes;

  // Number of OS threads that we're waiting for to be preempted for GC.
  int _gc_waiting_for_preemption;

  int _num_processes;
  int _next_group_id;
  int _next_process_id;
  int64 _next_tick = 0;
  ProcessListFromScheduler _ready_processes;

  int _num_threads;
  int _max_threads;
  SchedulerThreadList _threads;

  // Keep track of the number of ready processes with an active profiler.
  int _num_profiled_processes = 0;

  // Keep track of the boot process if it still alive.
  Process* _boot_process;

  // The scheduler keeps track of all live process groups. The linked
  // list is only manipulated while holding the scheduler mutex.
  ProcessGroupList _groups;

  friend class Process;
};

} // namespace toit

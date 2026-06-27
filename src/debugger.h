// Copyright (C) 2026 Toitware ApS.
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

#include <condition_variable>
#include <mutex>
#include <vector>

#include "os.h"
#include "top.h"

namespace toit {

class Locker;
class Process;
class Program;
class Scheduler;

// An in-image bytecode debugger speaking the line-based `dbg:` protocol over
// stdout/stdin. It is owned by the VM and active only when debugging is enabled
// (the `--debug` flag or the OEVM_DEBUG/TOIT_DEBUG environment variable).
//
// Threading model:
//   - The interpreter (a scheduler worker thread) calls `should_break` /
//     `on_pause` for every bytecode of a non-privileged process. On a hit it
//     returns DEBUG_PAUSED and the scheduler parks the process.
//   - `register_paused` runs on the scheduler thread, under the scheduler lock,
//     once the process is actually parked.
//   - A dedicated controller thread (NOT a scheduler worker, so it may block on
//     stdin) reads `dbg:` commands and re-readies parked processes via
//     `Scheduler::resume_debug_process`.
// The debugger's own state is guarded by `mutex_`; a condition variable hands
// off pause/target events between the threads.
class Debugger {
 public:
  // Reason a process paused. Passed to `on_pause`.
  enum Reason {
    REASON_BREAK,
    REASON_STEP,
  };

  explicit Debugger(Scheduler* scheduler);
  ~Debugger();

  bool active() const { return true; }

  // Print `dbg:ready` and start the controller thread. Call once, before the
  // target program runs.
  void start();

  // Stop the controller thread and join it. Must be called before the scheduler
  // is torn down so the controller can no longer touch it.
  void stop();

  // Called from the interpreter for every bytecode of a non-privileged process.
  // Returns true if execution should pause at `bci` (program-relative). Keys
  // breakpoints on (Program*, entry_bci, off). Also captures the first
  // non-privileged program and forces a pause at its entry so the operator can
  // install breakpoints before the program makes progress.
  bool should_break(Program* program, word bci);

  // Print the `dbg:paused ...` line for the current pause.
  void on_pause(Process* process, Program* program, word bci, int reason);

  // Install a breakpoint at `entry_bci + off` in `program`, reported as `id`.
  void add_breakpoint(Program* program, word entry_bci, word off, int id);

  // Called by the scheduler (under its lock) once a process has parked on a
  // DEBUG_PAUSED result. Records it and wakes a waiting controller command.
  void register_paused(Locker& locker, Process* process);

 private:
  struct Breakpoint {
    Program* program;
    word entry_bci;
    word off;
    int id;
  };

  class ControllerThread;

  // Controller-thread command handling.
  void run_controller();
  void handle_command(const char* line);
  void cmd_methods();
  void cmd_break(int id, int off);
  void cmd_continue();

  Scheduler* const scheduler_;
  ControllerThread* controller_ = null;

  std::mutex mutex_;
  std::condition_variable cond_;

  // The user program we are debugging (first non-privileged program seen).
  Program* target_program_ = null;
  std::vector<Breakpoint> breakpoints_;

  // The currently parked process (or -1 if none is parked).
  int paused_pid_ = -1;

  // Set during teardown to wake any waiting controller command and stop the
  // controller loop from touching the scheduler.
  bool stopped_ = false;

  // Information about the most recent pause, for `on_pause` to report. Only
  // touched on the single scheduler worker thread.
  int last_id_ = -1;
  word last_off_ = 0;

  // Minimal id->entry_bci registry built by `cmd_methods`, used by `cmd_break`.
  // (A full, name-resolving registry is Task 4.)
  std::vector<word> registry_entry_bcis_;
};

} // namespace toit

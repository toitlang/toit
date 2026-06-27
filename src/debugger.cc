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

#include "debugger.h"

#include <chrono>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "objects.h"
#include "process.h"
#include "program.h"
#include "scheduler.h"

namespace toit {

// The controller thread is a real OS thread (not a scheduler worker), so it is
// allowed to block on stdin while reading `dbg:` commands.
class Debugger::ControllerThread : public Thread {
 public:
  explicit ControllerThread(Debugger* debugger)
      : Thread("Debugger")
      , debugger_(debugger) {}

 protected:
  void entry() override { debugger_->run_controller(); }

 private:
  Debugger* const debugger_;
};

Debugger::Debugger(Scheduler* scheduler) : scheduler_(scheduler) {}

Debugger::~Debugger() {
  // The process is exiting; the controller thread (if blocked on stdin) is
  // reaped by the OS. We intentionally do not join it here to avoid hanging on
  // a blocking read during teardown.
  delete controller_;
}

void Debugger::start() {
  // The debugger uses STL containers (std::vector/std::condition_variable)
  // whose allocations go through the throwing global `operator new`, which the
  // VM normally forbids. Debugging is an opt-in, dev-only mode, so we lift the
  // guard for the session.
  throwing_new_allowed = true;
  printf("dbg:ready\n");
  fflush(stdout);
  controller_ = _new ControllerThread(this);
  if (controller_ == null) FATAL("Cannot allocate debugger controller thread");
  if (!controller_->spawn()) FATAL("Cannot spawn debugger controller thread");
}

void Debugger::stop() {
  { std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return;
    stopped_ = true;
    cond_.notify_all();
  }
  // Best-effort unblock of the controller's blocking stdin read; it also exits
  // when the operator (or the harness) closes stdin and the read sees EOF.
  close(STDIN_FILENO);
  if (controller_ != null) controller_->join();
}

bool Debugger::should_break(Program* program, word bci) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (target_program_ == null) {
    // First non-privileged program: bind the debugger to it and force a pause
    // at its entry so breakpoints can be installed before it makes progress.
    target_program_ = program;
    last_id_ = -1;
    last_off_ = 0;
    cond_.notify_all();
    return true;
  }
  if (program != target_program_) return false;
  for (auto& bp : breakpoints_) {
    if (program == bp.program && bci == bp.entry_bci + bp.off) {
      last_id_ = bp.id;
      last_off_ = bp.off;
      return true;
    }
  }
  return false;
}

void Debugger::on_pause(Process* process, Program* program, word bci, int reason) {
  const char* kind = reason == REASON_STEP ? "step" : "break";
  printf("dbg:paused %s %d %d\n", kind, last_id_, static_cast<int>(last_off_));
  fflush(stdout);
}

void Debugger::add_breakpoint(Program* program, word entry_bci, word off, int id) {
  std::lock_guard<std::mutex> lock(mutex_);
  breakpoints_.push_back(Breakpoint{program, entry_bci, off, id});
}

void Debugger::register_paused(Locker& locker, Process* process) {
  std::lock_guard<std::mutex> lock(mutex_);
  paused_pid_ = process->id();
  cond_.notify_all();
}

// --- Controller thread -----------------------------------------------------

void Debugger::run_controller() {
  // Line-buffered reader over stdin. We use raw read() so we are not affected
  // by stdio buffering of the (possibly shared) stdin stream.
  char buffer[512];
  int length = 0;
  while (true) {
    { std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) break;
    }
    char c;
    int n = read(STDIN_FILENO, &c, 1);
    if (n <= 0) break;  // EOF or error: the session is over.
    if (c == '\n') {
      buffer[length] = '\0';
      handle_command(buffer);
      length = 0;
    } else if (length < static_cast<int>(sizeof(buffer)) - 1) {
      buffer[length++] = c;
    }
  }
}

void Debugger::handle_command(const char* line) {
  if (strcmp(line, "dbg:methods") == 0) {
    cmd_methods();
  } else if (strncmp(line, "dbg:break ", 10) == 0) {
    int id = 0;
    int off = 0;
    if (sscanf(line + 10, "%d %d", &id, &off) == 2) {
      cmd_break(id, off);
    }
  } else if (strcmp(line, "dbg:continue") == 0) {
    cmd_continue();
  }
  // Unknown verbs are silently ignored in this task; the full verb set and
  // error reporting arrive in later tasks.
}

void Debugger::cmd_methods() {
  // Wait until the target program is known (it is captured when the first
  // non-privileged process runs and parks at its entry).
  Program* program;
  { std::unique_lock<std::mutex> lock(mutex_);
    cond_.wait(lock, [this] { return target_program_ != null || stopped_; });
    if (stopped_) return;
    program = target_program_;
    registry_entry_bcis_.clear();
  }

  // Minimal registry: enumerate the program's methods from the dispatch table,
  // deduplicating by entry bci. 1-based ids; emit `<id> <entry_bci> <arity>`.
  std::vector<word> seen;
  int id = 0;
  for (int i = 0; i < program->dispatch_table.length(); i++) {
    int32 header_bci = program->dispatch_table[i];
    if (header_bci < 0) continue;
    Method method(&program->bytecodes[header_bci]);
    word entry_bci = program->absolute_bci_from_bcp(method.entry());
    bool duplicate = false;
    for (auto e : seen) {
      if (e == entry_bci) { duplicate = true; break; }
    }
    if (duplicate) continue;
    seen.push_back(entry_bci);
    id++;
    registry_entry_bcis_.push_back(entry_bci);
    printf("%d %d %d\n", id, static_cast<int>(entry_bci), method.arity());
  }
  printf("dbg:ok methods\n");
  fflush(stdout);
}

void Debugger::cmd_break(int id, int off) {
  Program* program;
  word entry_bci;
  { std::lock_guard<std::mutex> lock(mutex_);
    program = target_program_;
    if (program == null || id < 1 || id > static_cast<int>(registry_entry_bcis_.size())) {
      return;
    }
    entry_bci = registry_entry_bcis_[id - 1];
  }
  add_breakpoint(program, entry_bci, off, id);
  printf("dbg:ok break\n");
  fflush(stdout);
}

void Debugger::cmd_continue() {
  int pid;
  { std::unique_lock<std::mutex> lock(mutex_);
    // Wait briefly for a parked process. Bounded so that surplus `continue`
    // commands (after the program has finished) do not block forever.
    cond_.wait_for(lock, std::chrono::milliseconds(800),
                   [this] { return paused_pid_ != -1 || stopped_; });
    if (stopped_ || paused_pid_ == -1) return;  // Nothing parked: ignore.
    pid = paused_pid_;
    paused_pid_ = -1;
  }
  // Resume outside our own lock: resume_debug_process takes the scheduler lock.
  scheduler_->resume_debug_process(pid, 0);
}

} // namespace toit

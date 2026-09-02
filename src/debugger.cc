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
  } else if (strncmp(line, "dbg:clear ", 10) == 0) {
    int id = 0;
    int off = 0;
    if (sscanf(line + 10, "%d %d", &id, &off) == 2) {
      cmd_clear(id, off);
    }
  } else if (strcmp(line, "dbg:inspect") == 0) {
    cmd_inspect(0);
  } else if (strncmp(line, "dbg:inspect ", 12) == 0) {
    int frame = 0;
    if (sscanf(line + 12, "%d", &frame) == 1) cmd_inspect(frame);
  } else if (strcmp(line, "dbg:continue") == 0) {
    cmd_continue();
  } else if (strcmp(line, "dbg:step") == 0) {
    cmd_step(1, "step");
  } else if (strcmp(line, "dbg:over") == 0) {
    cmd_step(2, "over");
  } else if (strcmp(line, "dbg:out") == 0) {
    cmd_step(3, "out");
  }
  // Unknown verbs are silently ignored in this task; the full verb set and
  // error reporting arrive in later tasks.
}

// Returns the target program once it is known, or null if the session is
// stopping. Blocks until the first non-privileged process has parked at its
// entry (which is when `target_program_` is captured).
Program* Debugger::await_target() {
  std::unique_lock<std::mutex> lock(mutex_);
  cond_.wait(lock, [this] { return target_program_ != null || stopped_; });
  if (stopped_) return null;
  return target_program_;
}

void Debugger::build_registry(Program* program) {
  // Cached per program: the registry is immutable for a given program. It is
  // built/read on the controller thread, but `resolve_step_location` reads it
  // from the scheduler thread, so the mutation is guarded by `mutex_`.
  if (registry_program_ == program) return;

  // Enumerate the program's methods from its dispatch table, deduplicating by
  // entry bci (a method may appear under several dispatch indices). 1-based ids
  // are simply the position in `registry_`. We keep the dispatch-table order
  // (rather than sorting) so ids stay identical to Task 2's enumeration.
  std::vector<MethodInfo> built;
  std::vector<word> seen;
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
    built.push_back(MethodInfo{entry_bci, method.arity()});
  }

  std::lock_guard<std::mutex> lock(mutex_);
  registry_program_ = program;
  registry_ = std::move(built);
}

void Debugger::resolve_step_location(Program* program, word bci) {
  std::lock_guard<std::mutex> lock(mutex_);
  // The containing method is the one with the greatest entry bci <= bci. If the
  // registry has not been built yet (no `dbg:methods` issued), fall back to the
  // absolute bci with an unknown id, mirroring the stop-at-entry pause.
  word best_entry = -1;
  int best_id = -1;
  for (int i = 0; i < static_cast<int>(registry_.size()); i++) {
    word entry = registry_[i].entry_bci;
    if (entry <= bci && entry > best_entry) {
      best_entry = entry;
      best_id = i + 1;
    }
  }
  last_id_ = best_id;
  last_off_ = best_entry < 0 ? bci : (bci - best_entry);
}

void Debugger::cmd_methods() {
  Program* program = await_target();
  if (program == null) return;
  build_registry(program);

  // One line per method: `<id> <entry_bci> <arity>`, then the terminator.
  for (int i = 0; i < static_cast<int>(registry_.size()); i++) {
    const MethodInfo& method = registry_[i];
    printf("%d %d %d\n", i + 1, static_cast<int>(method.entry_bci), method.arity);
  }
  printf("dbg:ok methods\n");
  fflush(stdout);
}

void Debugger::cmd_break(int id, int off) {
  Program* program = await_target();
  if (program == null) return;
  build_registry(program);
  if (id < 1 || id > static_cast<int>(registry_.size())) {
    printf("dbg:error no-method\n");
    fflush(stdout);
    return;
  }
  add_breakpoint(program, registry_[id - 1].entry_bci, off, id);
  printf("dbg:ok break\n");
  fflush(stdout);
}

void Debugger::cmd_clear(int id, int off) {
  Program* program = await_target();
  if (program == null) return;
  build_registry(program);
  if (id < 1 || id > static_cast<int>(registry_.size())) {
    printf("dbg:error no-method\n");
    fflush(stdout);
    return;
  }
  word entry_bci = registry_[id - 1].entry_bci;
  // Clearing is idempotent: removing a breakpoint that was never set still
  // reports `dbg:ok clear`. Only an unknown id is an error (handled above).
  { std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = breakpoints_.begin(); it != breakpoints_.end();) {
      if (it->program == program && it->entry_bci == entry_bci && it->off == off) {
        it = breakpoints_.erase(it);
      } else {
        ++it;
      }
    }
  }
  printf("dbg:ok clear\n");
  fflush(stdout);
}

void Debugger::cmd_inspect(int frame_index) {
  int pid;
  { std::unique_lock<std::mutex> lock(mutex_);
    // Wait briefly for a parked process; do NOT clear paused_pid_ — inspection
    // leaves the process parked so the operator can continue (or inspect again).
    cond_.wait_for(lock, std::chrono::milliseconds(800),
                   [this] { return paused_pid_ != -1 || stopped_; });
    if (stopped_ || paused_pid_ == -1) return;  // Nothing parked: ignore.
    pid = paused_pid_;
  }
  // Read the parked stack under the scheduler lock (emit_stack does the output).
  scheduler_->inspect_debug_process(pid, this, frame_index);
}

void Debugger::emit_string(String* string) {
  // Cap the emitted content so a huge string cannot flood the wire; the operator
  // UI shows a value, not the whole heap. Truncation is marked with an ellipsis
  // inside the quotes.
  static const word MAX_CHARS = 128;
  String::Bytes bytes(string);
  word length = bytes.length();
  word emit = length < MAX_CHARS ? length : MAX_CHARS;
  putchar('"');
  for (word i = 0; i < emit; i++) {
    uint8 c = bytes.at(i);
    switch (c) {
      case '"':  printf("\\\""); break;
      case '\\': printf("\\\\"); break;
      case '\n': printf("\\n"); break;
      case '\r': printf("\\r"); break;
      case '\t': printf("\\t"); break;
      default:
        if (c < 0x20) {
          printf("\\x%02x", c);
        } else {
          putchar(c);
        }
    }
  }
  if (length > emit) printf("...");
  putchar('"');
}

void Debugger::emit_stack(Locker& locker, Process* process, int frame_index) {
  Program* program = process->program();
  Stack* stack = process->task()->stack();
  word off = stack->frame_absolute_bci(program, frame_index);
  int count = stack->frame_register_count(program, frame_index);
  printf("dbg:stack off=%d", static_cast<int>(off));
  for (int i = 0; i < count; i++) {
    Object* value = stack->frame_register(program, frame_index, i);
    if (is_smi(value)) {
      printf(" r%d=%lld", i, static_cast<long long>(Smi::value(value)));
    } else if (value == program->null_object()) {
      printf(" r%d=null", i);
    } else if (value == program->true_object()) {
      printf(" r%d=true", i);
    } else if (value == program->false_object()) {
      printf(" r%d=false", i);
    } else if (is_double(value)) {
      printf(" r%d=%g", i, Double::cast(value)->value());
    } else if (is_string(value)) {
      printf(" r%d=", i);
      emit_string(String::cast(value));
    } else {
      // Heap object: emit the numeric class id. The operator-side tool resolves
      // the class name offline (the wire protocol stays "VM numeric, names
      // resolved offline").
      int class_id = Smi::value(HeapObject::cast(value)->class_id());
      printf(" r%d=<obj:%d>", i, class_id);
    }
  }
  printf("\n");
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

void Debugger::cmd_step(int step_mode, const char* verb) {
  int pid;
  { std::unique_lock<std::mutex> lock(mutex_);
    cond_.wait_for(lock, std::chrono::milliseconds(800),
                   [this] { return paused_pid_ != -1 || stopped_; });
    if (stopped_ || paused_pid_ == -1) return;  // Nothing parked: ignore.
    pid = paused_pid_;
    paused_pid_ = -1;
  }
  // Resume the target in the requested step mode. The interpreter captures the
  // start depth on the resumed bytecode and pauses again per the step rule.
  scheduler_->resume_debug_process(pid, step_mode);
  printf("dbg:ok %s\n", verb);
  fflush(stdout);
}

} // namespace toit

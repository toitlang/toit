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

#include "interpreter.h"

#include "flags.h"
#include "heap_report.h"
#include "objects_inline.h"
#include "printing.h"
#include "process.h"
#include "scheduler.h"
#include "vm.h"

#include <cmath> // isnan, isinf

namespace toit {

Interpreter::Interpreter()
    : _process(null)
    , _limit(null)
    , _base(null)
    , _sp(null)
    , _try_sp(null)
    , _watermark(null)
    , _in_stack_overflow(false) {
#ifdef PROFILER
  _is_profiler_active = false;
#endif
}

void Interpreter::activate(Process* process) {
  _process = process;
}

void Interpreter::deactivate() {
  _process = null;
}

void Interpreter::preempt() {
  // TODO: Use overflow marker / signal.
  _watermark = PREEMPTION_MARKER;
}

#ifdef PROFILER
void Interpreter::profile_register_method(Method method) {
  int absolute_bci = process()->program()->absolute_bci_from_bcp(method.header_bcp());
  Profiler* profiler = process()->profiler();
  if (profiler != null) profiler->register_method(absolute_bci);
}

void Interpreter::profile_increment(uint8* bcp) {
  int absolute_bci = process()->program()->absolute_bci_from_bcp(bcp);
  Profiler* profiler = process()->profiler();
  if (profiler != null) profiler->increment(absolute_bci);
}
#endif

Method Interpreter::lookup_entry() {
  Method result = _process->entry();
  if (!result.is_valid()) FATAL("Cannot locate entry method for interpreter");
  return result;
}

Object** Interpreter::load_stack() {
  Stack* stack = _process->task()->stack();
  stack->transfer_to_interpreter(this);
#ifdef PROFILER
  set_profiler_state();
#endif
  Object** watermark = _watermark;
  Object** new_watermark = _in_stack_overflow ? _limit : _limit + Stack::OVERFLOW_HEADROOM;
  while (true) {
    // Updates watermark unless preemption marker is set (will be set after preemption).
    if (watermark == PREEMPTION_MARKER) break;
    if (_watermark.compare_exchange_strong(watermark, new_watermark)) break;
  }
  return _sp;
}

void Interpreter::store_stack(Object** sp) {
  if (sp != null) _sp = sp;
  Stack* stack = _process->task()->stack();
  stack->transfer_from_interpreter(this);
  _limit = null;
  _base = null;
  _sp = null;

  Object** watermark = _watermark;
  while (true) {
    if (watermark == PREEMPTION_MARKER) break;
    if (_watermark.compare_exchange_strong(watermark, null)) break;
  }
}

void Interpreter::reset_stack_limit() {
  _in_stack_overflow = false;
  store_stack(null);
  load_stack();
}

#ifdef PROFILER
void Interpreter::set_profiler_state() {
  Profiler* profiler = process()->profiler();
  _is_profiler_active = profiler != null && profiler->should_profile_task(process()->task()->id());
}
#endif

void Interpreter::prepare_task(Method entry, Instance* code) {
  push(code);
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.entry()));
  push(_process->program()->frame_marker());

  push(Smi::from(0));  // Argument: stack
  push(Smi::from(0));  // Argument: value

  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.bcp_from_bci(LOAD_NULL_LENGTH)));
  push(_process->program()->frame_marker());
}

Object** Interpreter::scavenge(Object** sp, bool malloc_failed, int attempts, bool force_cross_process) {
  ASSERT(attempts >= 1 && attempts <= 3);  // Allocation attempts.
  if (attempts == 3) {
    OS::heap_summary_report(0, "out of memory");
    if (VM::current()->scheduler()->is_boot_process(_process)) {
      OS::out_of_memory("Out of memory in system process");
    }
    return sp;
  }
  store_stack(sp);
  VM::current()->scheduler()->scavenge(_process, malloc_failed, attempts > 1 || force_cross_process);
  return load_stack();
}

void Interpreter::prepare_process() {
  load_stack();

  Method entry = lookup_entry();
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.entry()));
  push(_process->program()->frame_marker());

  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.entry()));
  push(_process->program()->frame_marker());

  store_stack();
}

Object** Interpreter::check_stack_overflow(Object** sp, OverflowState* state, Method method) {
  ASSERT(*state == OVERFLOW_EXCEPTION);
  if (_watermark == PREEMPTION_MARKER) {
    if (_process->signals() & Process::WATCHDOG) {
      *state = OVERFLOW_WATCHDOG;
      return sp;
    }

    _watermark = null;
    *state = OVERFLOW_PREEMPT;
    return sp;
  }

  int length = _process->task()->stack()->length();
  if (length == Stack::max_length()) return sp;

  // The max_height doesn't include space for the frame of the next call (if there is one).
  // For simplicity just always assume that there will be a call at max-height and add `FRAME_SIZE`.
  int needed_space = method.max_height() + Interpreter::FRAME_SIZE + Stack::OVERFLOW_HEADROOM;
  int headroom = sp - _limit;
  ASSERT(headroom < needed_space);  // We shouldn't try to grow the stack otherwise.

  int new_length = Utils::max(length + (length >> 1), (length - headroom) + needed_space);
  new_length = Utils::min(Stack::max_length(), new_length);
  int new_headroom = headroom + (new_length - length);
  if (new_headroom < needed_space) return sp;  // Growing the stack will not bring us out of the red zone.
  Stack* new_stack = _process->object_heap()->allocate_stack(new_length);

  // Garbage collect up to three times.
  for (int attempts = 1; new_stack == null && attempts < 4; attempts++) {
#ifdef TOIT_GC_LOGGING
    if (attempts == 3) {
      printf("[gc @ %p%s | 3rd time stack allocate failure %d->%d]\n",
          _process, VM::current()->scheduler()->is_boot_process(_process) ? "*" : " ",
          length, new_length);
    }
#endif
    sp = scavenge(sp, false, attempts, false);
    new_stack = _process->object_heap()->allocate_stack(new_length);
  }

  // Then check for out of memory.
  if (new_stack == null) {
    *state = OVERFLOW_OOM;
    return sp;
  }

  store_stack(sp);
  _process->task()->stack()->copy_to(new_stack, new_length);
  _process->task()->set_stack(new_stack);
  sp = load_stack();
  *state = OVERFLOW_RESUME;
  return sp;
}

Method Interpreter::handle_stack_overflow(OverflowState state) {
  ASSERT(!_in_stack_overflow && _watermark != _limit);  // Stack overflow shouldn't occur while handling stack overflow.
  ASSERT(state == OVERFLOW_EXCEPTION || state == OVERFLOW_OOM);
  _watermark = _limit;
  _in_stack_overflow = true;
  if (state == OVERFLOW_EXCEPTION) {
    return _process->program()->stack_overflow();
  } else {
    return _process->program()->out_of_memory();
  }
}

Method Interpreter::handle_watchdog() {
  ASSERT(!_in_stack_overflow && _watermark != _limit);  // Watchdog shouldn't occur while handling stack overflow.
  reset_stack_limit();
  _process->clear_signal(Process::WATCHDOG);
  return _process->program()->watchdog();
}

void Interpreter::trace(uint8* bcp) {
#ifdef DEBUG
  auto program = _process->program();
  ConsolePrinter printer(program);
  printf("[%6d] ", program->absolute_bci_from_bcp(bcp));
  print_bytecode(&printer, bcp, 0);
  printf("\n");
  fflush(stdout);
#else
  UNIMPLEMENTED();
#endif
}

} // namespace toit

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

// We push the exception and two elements for the unwinding implementation
// on the stack when we handle stack overflows. This is in addition to the
// extra frame information we store for the call, because those are not
// reflected in the max-height of the called method. We do not keep track
// of where in a method we might do a call, so we conservatively assume
// that it will happen at max-height and reserve space for that.
static const int RESERVED_STACK_FOR_CALLS = Interpreter::FRAME_SIZE + 3;

Interpreter::Interpreter()
    : process_(null)
    , limit_(null)
    , base_(null)
    , sp_(null)
    , try_sp_(null)
    , watermark_(null) {}

void Interpreter::activate(Process* process) {
  process_ = process;
}

void Interpreter::deactivate() {
  process_ = null;
}

void Interpreter::preempt() {
  watermark_ = PREEMPTION_MARKER;
}

Method Interpreter::lookup_entry() {
  Method result = process_->entry();
  if (!result.is_valid()) FATAL("Cannot locate entry method for interpreter");
  return result;
}

Object** Interpreter::load_stack(Method* pending) {
  Stack* stack = process_->task()->stack();
  stack->transfer_to_interpreter(this);
  if (pending) {
    *pending = stack->pending_stack_check_method();
    stack->set_pending_stack_check_method(Method::invalid());
  }
  Object** watermark = watermark_;
  Object** new_watermark = limit_ + RESERVED_STACK_FOR_CALLS;
  while (true) {
    // Updates watermark unless preemption marker is set (will be set after preemption).
    if (watermark == PREEMPTION_MARKER) break;
    if (watermark_.compare_exchange_strong(watermark, new_watermark)) break;
  }
  return sp_;
}

void Interpreter::store_stack(Object** sp, Method pending) {
  if (sp != null) sp_ = sp;
  Stack* stack = process_->task()->stack();
  stack->transfer_from_interpreter(this);
  ASSERT(!stack->pending_stack_check_method().is_valid());
  if (pending.is_valid()) stack->set_pending_stack_check_method(pending);
  limit_ = null;
  base_ = null;
  sp_ = null;

  Object** watermark = watermark_;
  while (true) {
    if (watermark == PREEMPTION_MARKER) break;
    if (watermark_.compare_exchange_strong(watermark, null)) break;
  }
}

void Interpreter::prepare_task(Method entry, Instance* code) {
  push(code);
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.entry()));
  push(process_->program()->frame_marker());

  // Push the arguments to the faked call to 'task_transfer_'.
  push(process_->task());                     // Argument: to/Task
  push(process_->program()->false_object());  // Argument: detach_stack/bool

  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.bcp_from_bci(LOAD_NULL_LENGTH)));
  push(process_->program()->frame_marker());
}

Object** Interpreter::gc(Object** sp, bool malloc_failed, int attempts, bool force_cross_process) {
  ASSERT(attempts >= 1 && attempts <= 3);  // Allocation attempts.
  if (attempts == 3) {
    OS::heap_summary_report(0, "out of memory");
    if (VM::current()->scheduler()->is_boot_process(process_)) {
      OS::out_of_memory("Out of memory in system process");
    }
    return sp;
  }
  store_stack(sp);
  VM::current()->scheduler()->gc(process_, malloc_failed, attempts > 1 || force_cross_process);
  return load_stack();
}

void Interpreter::prepare_process() {
  load_stack();
  push(process_->task());

  Method entry = lookup_entry();
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.entry()));
  push(process_->program()->frame_marker());

  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  push(reinterpret_cast<Object*>(entry.entry()));
  push(process_->program()->frame_marker());

  store_stack();
}

#ifdef IOT_DEVICE
#define STACK_ENCODING_BUFFER_SIZE (2*1024)
#else
#define STACK_ENCODING_BUFFER_SIZE (16*1024)
#endif

// TODO(kasper): Share these definitions?
#define PUSH(o)            ({ Object* _o_ = o; *(--sp) = _o_; })
#define POP()              (*(sp++))
#define DROP(n)            ({ int _n_ = n; sp += _n_; })
#define STACK_AT(n)        ({ int _n_ = n; (*(sp + _n_)); })
#define STACK_AT_PUT(n, o) ({ int _n_ = n; Object* _o_ = o; *(sp + _n_) = _o_; })

Object** Interpreter::push_error(Object** sp, Object* type, const char* message) {
  Process* process = process_;
  PUSH(type);

  // Stack: Type, ...

  Instance* instance = process->object_heap()->allocate_instance(process->program()->exception_class_id());
  for (int attempts = 1; instance == null && attempts < 4; attempts++) {
    sp = gc(sp, false, attempts, false);
    instance = process->object_heap()->allocate_instance(process->program()->exception_class_id());
  }
  if (instance == null) {
    DROP(1);
    return push_out_of_memory_error(sp);
  }

  type = POP();
  PUSH(instance);
  PUSH(type);

  // Stack: Type, Instance, ...

  MallocedBuffer buffer(STACK_ENCODING_BUFFER_SIZE);
  for (int attempts = 1; !buffer.has_content() && attempts < 4; attempts++) {
    sp = gc(sp, true, attempts, false);
    buffer.allocate(STACK_ENCODING_BUFFER_SIZE);
  }
  if (!buffer.has_content()) {
    DROP(2);
    return push_out_of_memory_error(sp);
  }

  ProgramOrientedEncoder encoder(process->program(), &buffer);
  store_stack(sp);
  bool success = encoder.encode_error(STACK_AT(0), message, process->task()->stack());
  sp = load_stack();

  if (success) {
    ByteArray* trace = process->allocate_byte_array(buffer.size());
    for (int attempts = 1; trace == null && attempts < 4; attempts++) {
      sp = gc(sp, false, attempts, false);
      trace = process->allocate_byte_array(buffer.size());
    }
    if (trace == null) {
      DROP(2);
      return push_out_of_memory_error(sp);
    }
    ByteArray::Bytes bytes(trace);
    memcpy(bytes.address(), buffer.content(), buffer.size());
    PUSH(trace);
  } else {
    STACK_AT_PUT(0, process->program()->out_of_bounds());
    PUSH(process->program()->null_object());
  }

  // Stack: Trace, Type, Instance, ...

  instance = Instance::cast(STACK_AT(2));
  instance->at_put(1, POP());  // Trace.
  instance->at_put(0, POP());  // Type.
  return sp;
}

Object** Interpreter::push_out_of_memory_error(Object** sp) {
  PUSH(process_->program()->out_of_memory_error());
  return sp;
}

Object** Interpreter::handle_stack_overflow(Object** sp, OverflowState* state, Method method) {
  if (watermark_ == PREEMPTION_MARKER) {
    // Reset the watermark now that we're handling the preemption.
    watermark_ = null;
    *state = OVERFLOW_PREEMPT;
    return sp;
  }

  Process* process = process_;
  int length = process->task()->stack()->length();
  int new_length = -1;
  if (length < Stack::max_length()) {
    int needed_space = method.max_height() + RESERVED_STACK_FOR_CALLS;
    int headroom = sp - limit_;
    ASSERT(headroom < needed_space);  // We shouldn't try to grow the stack otherwise.

    new_length = Utils::max(length + (length >> 1), (length - headroom) + needed_space);
    new_length = Utils::min(Stack::max_length(), new_length);
    int new_headroom = headroom + (new_length - length);
    if (new_headroom < needed_space) new_length = -1;  // Growing the stack will not give us enough space.
  }

  if (new_length < 0) {
    *state = OVERFLOW_EXCEPTION;
    Object* type = process->program()->stack_overflow();
    return push_error(sp, type, "");
  }

  Stack* new_stack = process->object_heap()->allocate_stack(new_length);

  // Garbage collect up to three times.
  for (int attempts = 1; new_stack == null && attempts < 4; attempts++) {
#ifdef TOIT_GC_LOGGING
    if (attempts == 3) {
      printf("[gc @ %p%s | 3rd time stack allocate failure %d->%d]\n",
          process, VM::current()->scheduler()->is_boot_process(process) ? "*" : " ",
          length, new_length);
    }
#endif
    sp = gc(sp, false, attempts, false);
    new_stack = process->object_heap()->allocate_stack(new_length);
  }

  // Then check for out of memory.
  if (new_stack == null) {
    *state = OVERFLOW_EXCEPTION;
    return push_out_of_memory_error(sp);
  }

  store_stack(sp);
  process->task()->stack()->copy_to(new_stack, new_length);
  process->task()->set_stack(new_stack);
  sp = load_stack();
  *state = OVERFLOW_RESUME;
  return sp;
}

void Interpreter::trace(uint8* bcp) {
#ifdef TOIT_DEBUG
  auto program = process_->program();
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

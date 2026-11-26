// Copyright (C) 2026 Toit contributors.
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

// The C++ side of format-2 programs: the method table, the hand-over of
// format-2 processes to the verified core (verified/core), and the
// functions the core calls back. See interpreter_v2.h and
// verified/core/DESIGN.md.

#include "interpreter_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bytecodes.h"
#include "flags.h"
#include "encoder.h"
#include "heap_report.h"
#include "heap_roots.h"
#include "hw_perf.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "out_of_memory.h"
#include "process.h"
#include "process_group.h"
#include "program.h"
#include "scheduler.h"
#include "verifier.h"
#include "vm.h"

#include "third_party/dartino/gc_metadata.h"

static void v2_validate(toit::Process* process, const char* where);

// The hand-over to the core and the primitive calls run on every process
// switch and every C++ primitive call: in IRAM with the core's loop
// (TOIT_VERIFIED_CORE_LOOP_IN_IRAM). From flash they missed the flash cache
// after nearly every process switch on the classic ESP32
// (docs/format2-migration.md, "Devices: hardware results").
#if defined(TOIT_ESP32) && defined(CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM)
#define V2_HOT IRAM_ATTR
#else
#define V2_HOT
#endif

namespace toit {

// The method table itself (decoding, the table literal): v2_method_table.cc.

V2_HOT void v2_program_tables(Program* program, const V2MethodTable* table, Object** globals,
                       toit_v2_program* p) {
  memset(p, 0, sizeof(*p));
  p->bytecodes = program->bytecodes.data();
  p->bytecodes_length = program->bytecodes.length();
  p->methods = table->records();
  p->methods_length = table->length();
  p->dispatch = program->dispatch_table.data();
  p->dispatch_length = program->dispatch_table.length();
  p->class_bits = program->class_bits.data();
  p->class_bits_length = program->class_bits.length();
  p->class_check_ids = program->class_check_ids.data();
  p->class_check_ids_length = program->class_check_ids.length();
  p->interface_check_offsets = program->interface_check_offsets.data();
  p->interface_check_offsets_length = program->interface_check_offsets.length();
  p->invoke_offsets = reinterpret_cast<const int32*>(program->invoke_bytecode_offsets());
  p->entry_points = reinterpret_cast<const int32*>(program->entry_point_indexes());
  p->builtin_class_ids = reinterpret_cast<const uword*>(program->builtin_class_ids());
  p->roots = reinterpret_cast<const uword*>(program->roots());
  p->roots_length = Program::ROOT_COUNT;
  p->literals = reinterpret_cast<const uword*>(program->literals.array());
  p->literals_length = program->literals.length();
  p->globals = reinterpret_cast<uword*>(globals);
  p->globals_length = program->global_variables.length();
  p->program_heap_start = reinterpret_cast<uword>(program);
  p->program_heap_size = program->size_no_assets();
  p->remembered_set_bias = GcMetadata::remembered_set_bias();
  p->global_max_height = program->global_max_stack_height();
  p->stack_array_word = Stack::v2_array_word();
}


// --------------------------------------------------------------------------
// Running format-2 processes.

static const V2MethodTable* v2_table(Process* process) {
  const V2MethodTable* table = process->group()->v2_methods();
  if (table == null) FATAL("format-2 process without a method table");
  return table;
}

// The initial state (v2::prim::initial_state): the task as the only
// object-stack slot, one frame for the entry method.
void Interpreter::prepare_process_v2() {
  Program* program = process_->program();
  const V2MethodTable* table = v2_table(process_);
  bool spawned = process_->spawn_method().is_valid();
  word entry = table->entry_method(program, spawned ? Program::entry_spawn_INDEX : Program::entry_main_INDEX);
  if (entry < 0) FATAL("Cannot locate entry method for interpreter");
  Task* task = process_->task();
  Stack* stack = task->stack();
  word length = stack->length();
  if (length < Stack::V2_FRAME_WORDS + 1) FATAL("stack too small");
  stack->v2_word_at_put(length - 1, reinterpret_cast<uword>(task));
  stack->v2_set_top(length - 1);
  stack->v2_word_at_put(Stack::V2_FRAME_METHOD, entry);
  word bci = table->entry_of(entry);
  stack->v2_word_at_put(Stack::V2_FRAME_RET, bci);
  stack->v2_word_at_put(Stack::V2_FRAME_BASE, 0);
  stack->v2_word_at_put(Stack::V2_FRAME_HANDLER, 0);
  stack->v2_set_frame_top(Stack::V2_FRAME_WORDS);
  stack->v2_set_bci(bci);
  GcMetadata::insert_into_remembered_set(stack);
}

// A new task's first transfer (v2::prim::resume): the frames of
// `__entry__task(code)` having called the transferring method, which
// continues after its PRIMITIVE with [to] pushed by the core.
static bool v2_start_task(Process* process, Stack* from_stack, Stack* to_stack, Task* to) {
  Program* program = process->program();
  const V2MethodTable* table = v2_table(process);
  word entry = table->entry_method(program, Program::entry_task_INDEX);
  word frame_top = from_stack->v2_frame_top();
  if (entry < 0 || frame_top < Stack::V2_FRAME_WORDS) return false;
  word method = from_stack->v2_word_at(frame_top - Stack::V2_FRAME_WORDS + Stack::V2_FRAME_METHOD);
  word length = to_stack->length();
  if (to_stack->top() != length - 1 || length < 3 + 2 * Stack::V2_FRAME_WORDS + Stack::V2_STACK_RESERVE) {
    return false;
  }
  // The code is in the bottom slot already.
  to_stack->v2_word_at_put(length - 2, reinterpret_cast<uword>(to));
  to_stack->v2_word_at_put(length - 3, reinterpret_cast<uword>(program->false_object()));
  to_stack->v2_set_top(length - 3);
  word e = table->entry_of(entry);
  to_stack->v2_word_at_put(Stack::V2_FRAME_METHOD, entry);
  to_stack->v2_word_at_put(Stack::V2_FRAME_RET, e);
  to_stack->v2_word_at_put(Stack::V2_FRAME_BASE, 0);
  to_stack->v2_word_at_put(Stack::V2_FRAME_HANDLER, 0);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_METHOD, method);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_RET, e + 1);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_BASE, 1);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_HANDLER, 0);
  // No finally records (the spec's new task has none).
  to_stack->v2_set_records(2 * Stack::V2_FRAME_WORDS, 0, from_stack->v2_bci());
  GcMetadata::insert_into_remembered_set(to_stack);
  return true;
}

// `core.task_transfer` for format 2. The core has stored the running task's
// state into its stack before the call; after it, the core continues with
// whatever task is current, after its PRIMITIVE with [to] pushed (the
// failure path, as in format 1).
V2_HOT Object* Interpreter::v2_task_transfer(Process* process, Task* to, bool detach_stack) {
  Task* from = process->object_heap()->task();
  if (from != to) {
    if (!to->has_stack()) FAIL(ERROR);
    Stack* from_stack = from->stack();
    Stack* to_stack = to->stack();
    GcMetadata::insert_into_remembered_set(from_stack);
    if (to_stack->v2_frame_top() == 0) {
      if (!v2_start_task(process, from_stack, to_stack, to)) FATAL("cannot start task");
    }
    if (detach_stack) from->detach_stack();
    process->object_heap()->set_task(to);
  }
  return Primitive::mark_as_error(to);
}

V2_HOT Interpreter::Result Interpreter::run_v2() {
#ifdef TOIT_VERIFIED_CORE
  process_->object_heap()->leave_primitive();
  preemption_method_header_bcp_ = null;
  Program* program = process_->program();
  const V2MethodTable* table = v2_table(process_);
  toit_v2_context context;
  memset(&context, 0, sizeof(context));
  context.process = process_;
  v2_program_tables(program, table, process_->object_heap()->global_variables(), &context.program);
  context.watermark = &watermark_;
  context.preempt_a_lot = Flags::preempt_a_lot ? 1 : 0;
  // The verified loop for a table the launch-time verifier accepted, under
  // the untrusted rules for an untrusted process; and for any trusted
  // process (TOIT_V2_TRUSTED: we trust the compiler for first-party code).
  bool untrusted = process_->policy()->is_untrusted();
  bool accepted = table->runs_verified(untrusted);
  bool trusted = !accepted && !untrusted && V2MethodTable::trusted_on_verified_loop();
  // Without the checked loop (devices) ProcessGroup::create admits only
  // programs that run on the verified loop.
  if (!accepted && !trusted && !V2MethodTable::checked_loop_linked()) {
    FATAL("format-2 program not verified and no checked loop");
  }
  context.accepted = accepted ? TOIT_V2_ACCEPTED : (trusted ? TOIT_V2_TRUSTED : 0);
  // The core runs the Rust port of a core primitive only where the policy
  // resolves it to the VM's own primitive (never a denying stub).
  context.core_arities = process_->policy()->core_arities();
  context.core_arities_length = context.core_arities == null ? 0 : process_->policy()->core_arities_length();
  context.epoch = process_->object_heap()->v2_epoch_address();
  context.new_space_top = process_->object_heap()->v2_new_space_top_address();
  context.new_space_limit = process_->object_heap()->v2_new_space_limit_address();
  // Trusted programs may use the unchecked twins of the field accesses
  // (format note 20; the compiler emits them with -Xv2_unchecked). Never an
  // untrusted process: its launch verification rejects them.
  context.unchecked = !untrusted ? 1 : 0;

  v2_validate(process_, "run entry");
  toit_v2_run(&context);
  v2_validate(process_, "run exit");
  if (Flags::trace) printf("[exit core interpretation state=%d]\n", static_cast<int>(context.result_state));

  GcMetadata::insert_into_remembered_set(process_->task()->stack());
  Object** watermark = watermark_;
  while (watermark != PREEMPTION_MARKER) {
    if (watermark_.compare_exchange_strong(watermark, null)) break;
  }
  Result::State state = static_cast<Result::State>(context.result_state);
  if (state == Result::PREEMPTED) {
    // For the profiler (Scheduler::run_process): the method of the top
    // frame, whose bci the stack holds.
    Stack* stack = process_->task()->stack();
    word frame_top = stack->v2_frame_top();
    if (frame_top >= Stack::V2_FRAME_WORDS) {
      word method = stack->v2_word_at(frame_top - Stack::V2_FRAME_WORDS + Stack::V2_FRAME_METHOD);
      if (table->is_valid(method)) {
        preemption_method_header_bcp_ = program->bytecodes.data() + table->header_of(method);
      }
    }
  }
  return Result(state, context.result_value);
#else
  FATAL("format-2 programs need the verified core (TOIT_VERIFIED_CORE)");
#endif
}

#ifdef TOIT_NO_CXX_INTERPRETER
// Without the C++ interpreter (interpreter_run.cc is not linked) every
// program is format 2: ProcessGroup::create refuses format-1 programs.
V2_HOT Interpreter::Result Interpreter::run() {
  if (!process_->program()->is_format2()) FATAL("format-1 program and no C++ interpreter");
  return run_v2();
}
#endif

}  // namespace toit

// --------------------------------------------------------------------------
// The functions the core calls.

using namespace toit;

static Process* v2_process(void* process) {
  return static_cast<Process*>(process);
}

// Debugging aid (TOIT_V2_VALIDATE=1): checks that every object-stack slot
// of the current task is a smi or points to something with a plausible
// header. Hosts only: devices have no environment.
#ifdef TOIT_FREERTOS
static void v2_validate(Process* process, const char* where) {}
#else
static void v2_validate(Process* process, const char* where) {
  static int enabled = -1;
  if (enabled < 0) enabled = getenv("TOIT_V2_VALIDATE") != null ? 1 : 0;
  if (!enabled) return;
  Program* program = process->program();
  auto check = [&](Stack* stack, const char* which) {
  word length = stack->length();
  word top = stack->top();
  uword from = reinterpret_cast<uword>(program->bytecodes.data());
  uword to = from + program->bytecodes.length();
  for (word i = top; i < length; i++) {
    uword w = stack->v2_word_at(i);
    if ((w & 1) == 0) continue;
    if (from <= w && w < to) continue;
    uword header = *reinterpret_cast<uword*>(w - 1);
    word tag = (header >> 1) & 15;
    if ((header & 1) != 0 || (w & 3) != 1 || tag > 9) {
      fprintf(stderr, "v2_validate(%s, %s stack %p): bad slot %" PRIdPTR " (position %" PRIdPTR ") = %p header %p; top %" PRIdPTR " length %" PRIdPTR " frame top %" PRIdPTR " bci %" PRIdPTR "\n",
              where, which, reinterpret_cast<void*>(stack), i, length - 1 - i, reinterpret_cast<void*>(w), reinterpret_cast<void*>(header),
              top, length, stack->v2_frame_top(), stack->v2_bci());
      abort();
    }
  }
  };
  Stack* current = process->task()->stack();
  check(current, "current");
  process->object_heap()->do_objects([&](HeapObject* object) {
    if (!is_task(object)) return;
    Task* task = Task::cast(object);
    if (!task->has_stack()) return;
    Stack* stack = task->stack();
    if (stack != current) check(stack, "other task's");
  });
}
#endif

static void v2_report_allocation_failure(Process* process, const char* reason, word parameter1, word parameter2) {
  report_allocation_failure(process, reason, parameter1, parameter2);
}

// As Interpreter::gc, without moving the interpreter's stack pointers (the
// core has stored its state into the stack object).
static void v2_gc(Process* process, bool malloc_failed, int attempts, bool force_cross_process,
                  const char* reason, word parameter1 = 0, word parameter2 = 0) {
  if (attempts == 3) {
    v2_report_allocation_failure(process, reason, parameter1, parameter2);
    return;
  }
  GcMetadata::insert_into_remembered_set(process->task()->stack());
  v2_validate(process, "gc");
  VM::current()->scheduler()->gc(process, malloc_failed, attempts > 1 || force_cross_process);
  v2_validate(process, "after gc");
}

template <typename F>
static uword v2_allocate(Process* process, const char* reason, F allocate) {
  HW_PERF_SCOPE(HWP_ALLOC);
  HeapObject* result = allocate();
  for (int attempts = 1; result == null && attempts < 4; attempts++) {
    v2_gc(process, false, attempts, false, reason);
    result = allocate();
  }
  process->object_heap()->leave_primitive();
  return reinterpret_cast<uword>(result);
}

#ifdef TOIT_FREERTOS
#define V2_STACK_ENCODING_BUFFER_SIZE (2*1024)
#else
#define V2_STACK_ENCODING_BUFFER_SIZE (16*1024)
#endif

extern "C" {

V2_HOT uword toit_v2_current_stack(void* process) {
  return reinterpret_cast<uword>(v2_process(process)->task()->stack());
}

uword toit_v2_allocate_instance(void* raw_process, uword class_id) {
  Process* process = v2_process(raw_process);
  return v2_allocate(process, "'allocate instance'", [&]() -> HeapObject* {
    return process->object_heap()->allocate_instance(Smi::from(class_id));
  });
}

uword toit_v2_allocate_exception(void* raw_process, uword raw_value, uword message_kind,
                                 const uword* words, uword count) {
  Process* process = v2_process(raw_process);
  Program* program = process->program();
  Object* value = reinterpret_cast<Object*>(raw_value);
  // The trace, as Interpreter::push_error encodes it, with the raising
  // method as the top frame. Optional: a failure leaves the trace null.
  // The message words are only used here, before the first GC point.
  Object* trace = process->null_object();
  MallocedBuffer buffer(V2_STACK_ENCODING_BUFFER_SIZE);
  if (buffer.has_content()) {
    ProgramOrientedEncoder encoder(program, &buffer);
    Stack* stack = process->task()->stack();
    Object* const* elements = reinterpret_cast<Object* const*>(words);
    if (count > TOIT_V2_MESSAGE_MAX_WORDS) count = 0;
    Stack::v2_frames_skip_ = 0;
    bool success;
    if (message_kind == TOIT_V2_MESSAGE_WORD && count == 1) {
      success = encoder.encode_error(value, elements[0], stack);
    } else if (message_kind == TOIT_V2_MESSAGE_ARRAY) {
      success = encoder.encode_error(value, elements, count, stack);
    } else if (message_kind == TOIT_V2_MESSAGE_PRIMITIVE && count == 2) {
      char message[64];
      snprintf(message, sizeof(message), "Failed to find primitive %d:%d",
               static_cast<int>(words[0]), static_cast<int>(words[1]));
      success = encoder.encode_error(value, message, stack);
    } else {
      success = encoder.encode_error(value, "", stack);
    }
    Stack::v2_frames_skip_ = 2;
    if (success) {
      word size = buffer.size();
      uword bytes = v2_allocate(process, "'raising'", [&]() -> HeapObject* {
        return process->allocate_byte_array(size);
      });
      if (bytes != 0) {
        ByteArray::Bytes content(reinterpret_cast<ByteArray*>(bytes));
        memcpy(content.address(), buffer.content(), size);
        trace = reinterpret_cast<Object*>(bytes);
      }
    }
  }
  HeapRoot root(trace);
  process->object_heap()->add_external_root(&root);
  Smi* class_id = program->exception_class_id();
  uword result = v2_allocate(process, "'raising'", [&]() -> HeapObject* {
    return process->object_heap()->allocate_instance(class_id);
  });
  process->object_heap()->remove_external_root(&root);
  if (result == 0) return 0;
  Instance* instance = reinterpret_cast<Instance*>(result);
  instance->at_put(0, value);
  instance->at_put(1, *root);
  return result;
}

uword toit_v2_allocate_double(void* raw_process, uint64 bits) {
  Process* process = v2_process(raw_process);
  double value = bit_cast<double>(bits);
  return v2_allocate(process, "'allocate double'", [&]() -> HeapObject* {
    return process->object_heap()->allocate_double(value);
  });
}

uword toit_v2_allocate_array(void* raw_process, uword length, uword filler) {
  Process* process = v2_process(raw_process);
  if (length > static_cast<uword>(Array::max_length_in_process())) return 0;
  return v2_allocate(process, "'allocate array'", [&]() -> HeapObject* {
    return process->object_heap()->allocate_array(length, reinterpret_cast<Object*>(filler));
  });
}

uword toit_v2_grow_stack(void* raw_process, uword needed) {
  Process* process = v2_process(raw_process);
  // More free words than the longest stack has: an overflow (checked here, so
  // that the casts to `word` below never see a value of 2^(WORD_BITS-1) or
  // more; the core passes less than 2^20, GROW_STACK_MAX_NEEDED in
  // verified/core/src/layout.rs).
  if (needed > static_cast<uword>(Stack::max_length())) return TOIT_V2_STACK_OVERFLOW;
  Stack* stack = process->task()->stack();
  // The core has written into the stack since it was last remembered. The
  // old stack becomes garbage, but the collector still scans it whenever
  // its card is dirty (old space is swept, not traced, between scavenges),
  // so its new-space pointers must stay up to date: remember it now, as
  // Interpreter::store_stack does for format 1.
  GcMetadata::insert_into_remembered_set(stack);
  word length = stack->length();
  word free = stack->top() - stack->v2_record_top();
  word new_length = -1;
  if (length < Stack::max_length()) {
    new_length = Utils::max(length + (length >> 1), (length - free) + static_cast<word>(needed));
    new_length = Utils::min(Stack::max_length(), new_length);
    if (free + (new_length - length) < static_cast<word>(needed)) new_length = -1;
  }
  if (new_length < 0) return TOIT_V2_STACK_OVERFLOW;
  Stack* new_stack = process->object_heap()->allocate_stack(new_length);
  for (int attempts = 1; new_stack == null && attempts < 4; attempts++) {
    v2_gc(process, false, attempts, false, "'stack grow'", length, new_length);
    new_stack = process->object_heap()->allocate_stack(new_length);
  }
  process->object_heap()->leave_primitive();
  if (new_stack == null) return TOIT_V2_OUT_OF_MEMORY;
  // The GC may have moved or shrunk the old stack.
  stack = process->task()->stack();
  stack->v2_copy_to(new_stack);
  process->task()->set_stack(new_stack);
  return TOIT_V2_OK;
}

uword toit_v2_try_allocate_large_integer(void* raw_process, int64 value) {
  return reinterpret_cast<uword>(v2_process(raw_process)->object_heap()->allocate_large_integer(value));
}

uword toit_v2_try_allocate_double(void* raw_process, uint64 bits) {
  double value = bit_cast<double>(bits);
  return reinterpret_cast<uword>(v2_process(raw_process)->object_heap()->allocate_double(value));
}

uword toit_v2_try_allocate_array(void* raw_process, uword length, void* filler) {
  if (length > static_cast<uword>(Array::ARRAYLET_SIZE)) {
    return 0;
  }
  return reinterpret_cast<uword>(v2_process(raw_process)->object_heap()->allocate_array(
      length, static_cast<Object*>(filler)));
}

// The longest blob the core's allocation makes: the bound of both heap
// models (below the core's MAX_BLOB_LENGTH, 2^62 on 64-bit and 2^30 on
// 32-bit; the VeriFast model's MAX_BLOB). A longer one is left to the C++
// primitive: the allocation returns 0, the core's port declines. The bound
// also keeps Process::allocate_string's `length + 1` from overflowing.
static const uword V2_MAX_BLOB_LENGTH = UINTPTR_MAX / 4;

uword toit_v2_try_allocate_string(void* raw_process, uword length) {
  if (length > V2_MAX_BLOB_LENGTH) return 0;
  return reinterpret_cast<uword>(v2_process(raw_process)->allocate_string(length));
}

uword toit_v2_try_allocate_byte_array(void* raw_process, uword length) {
  if (length > V2_MAX_BLOB_LENGTH) return 0;
  return reinterpret_cast<uword>(v2_process(raw_process)->allocate_byte_array(length));
}

// The GC-and-retry protocol of a C++ primitive whose first call returned the
// error [result] (the C++ interpreter's loop after its first call). Out of
// line: the common call returns a value or a failure without collecting.
static __attribute__((noinline)) V2_HOT uword v2_primitive_failed(
    Process* process, Primitive::Entry* entry, uword module, uword index, uword first_argument, Object* result,
    uword* result_out) {
  Program* program = process->program();
  v2_validate(process, "primitive failure");
  for (int attempts = 1; true; attempts++) {
    if (!Primitive::is_error(result)) {
      process->object_heap()->leave_primitive();
      *result_out = reinterpret_cast<uword>(result);
      return TOIT_V2_PRIMITIVE_SUCCESS;
    }
    result = Primitive::unmark_from_error(program, result);
    bool malloc_failed = (result == program->malloc_failed());
    bool allocation_failed = (result == program->allocation_failed());
    bool force_cross_process = false;
    if (result == program->cross_process_gc()) {
      force_cross_process = true;
      malloc_failed = true;
    } else if (!(malloc_failed || allocation_failed)) {
      break;
    }
    if (attempts > 3) {
      process->object_heap()->leave_primitive();
      *result_out = reinterpret_cast<uword>(result);
      return TOIT_V2_PRIMITIVE_THROW;
    }
    v2_gc(process, malloc_failed, attempts, force_cross_process, "primitive",
          static_cast<word>(module), static_cast<word>(index));
    Stack* stack = process->task()->stack();
    // A moving collection can replace the stack and clear its old card.
    GcMetadata::insert_into_remembered_set(stack);
    result = entry(process, stack->v2_slot_address(first_argument));
  }
  process->object_heap()->leave_primitive();
  *result_out = reinterpret_cast<uword>(result);
  return TOIT_V2_PRIMITIVE_FAILURE;
}

V2_HOT uword toit_v2_primitive(void* raw_process, uword module, uword index, uword arity,
                        uword first_argument, uword* result_out) {
  Process* process = v2_process(raw_process);
  const PrimitiveEntry* primitive = process->policy()->at(module, index);
  if (Flags::primitives) printf("[invoking primitive %d::%d]\n", static_cast<int>(module), static_cast<int>(index));
  if (primitive == null || static_cast<uword>(primitive->arity) != arity) return TOIT_V2_PRIMITIVE_ABSENT;
  Primitive::Entry* entry = reinterpret_cast<Primitive::Entry*>(primitive->function);
  // The core stores into the stack without the write barrier: a GC during
  // the primitive must find the stack in the remembered set.
  Stack* stack = process->task()->stack();
  GcMetadata::insert_into_remembered_set(stack);
  HW_PERF_PRIMITIVE_START(hw_perf_start);
  Object* result = entry(process, stack->v2_slot_address(first_argument));
  HW_PERF_PRIMITIVE_END(hw_perf_start, module, index);
  if (Primitive::is_error(result)) {
    // A plain failure (not an allocation failure that asks for a GC and a
    // retry) completes here: the transfer to another task and the yield
    // return through it (rpc-task-speed-3). The GC-and-retry protocol is
    // out of line.
    Program* program = process->program();
    v2_validate(process, "primitive failure");
    Object* error = Primitive::unmark_from_error(program, result);
    if (error != program->malloc_failed() && error != program->allocation_failed() &&
        error != program->cross_process_gc()) {
      process->object_heap()->leave_primitive();
      *result_out = reinterpret_cast<uword>(error);
      return TOIT_V2_PRIMITIVE_FAILURE;
    }
    return v2_primitive_failed(process, entry, module, index, first_argument, result, result_out);
  }
  process->object_heap()->leave_primitive();
  *result_out = reinterpret_cast<uword>(result);
  return TOIT_V2_PRIMITIVE_SUCCESS;
}

void toit_v2_report(void* raw_process, uword kind, uword bci, uword detail) {
  switch (kind) {
    case TOIT_V2_REPORT_STUCK:
      fprintf(stderr, "verified core: stuck state %d at bci %d: terminating the process\n",
              static_cast<int>(detail), static_cast<int>(bci));
      break;
    case TOIT_V2_REPORT_UNCAUGHT:
      fprintf(stderr, "verified core: uncaught exception at bci %d: terminating the process\n",
              static_cast<int>(bci));
      break;
    case TOIT_V2_REPORT_TASK_RETURNED:
      fprintf(stderr, "verified core: the bottom frame returned at bci %d: terminating the process\n",
              static_cast<int>(bci));
      break;
    case TOIT_V2_REPORT_TRACE: {
      // Like Interpreter::trace, but with the format-2 opcode number (see
      // verified/tools/compare_trace.toit). With TOIT_V2_TRACE_PROCESS set
      // (format-3 study, verified/format3-study) each line also names the
      // process and its program, so that traces of several processes can
      // be told apart.
      static int with_process = -1;
      if (with_process < 0) with_process = getenv("TOIT_V2_TRACE_PROCESS") != null ? 1 : 0;
      if (with_process) {
        Process* process = reinterpret_cast<Process*>(raw_process);
        printf("[%6d] #%d p%d g%x\n", static_cast<int>(bci), static_cast<int>(detail), process->id(),
               static_cast<unsigned>(reinterpret_cast<uword>(process->program()) & 0xffffff));
      } else {
        printf("[%6d] #%d\n", static_cast<int>(bci), static_cast<int>(detail));
      }
      break;
    }
  }
}

uword toit_v2_tracing(void* raw_process) {
  return Flags::trace ? 1 : 0;
}

}  // extern "C"

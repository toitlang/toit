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
#include <string.h>

#include "bytecodes.h"
#include "flags.h"
#include "encoder.h"
#include "heap_report.h"
#include "heap_roots.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "process.h"
#include "process_group.h"
#include "program.h"
#include "scheduler.h"
#include "vm.h"

#include "third_party/dartino/gc_metadata.h"

static void v2_validate(toit::Process* process, const char* where);

namespace toit {


static const int V2_TAG_SIZE = 4;
static const int V2_KIND_MASK = 0x3;
static const int V2_HAS_SELECTOR = 1 << 2;
static const int V2_HAS_RECEIVER = 1 << 3;
static const int V2_MAX_LEB_BYTES = 4;

// Format-2 opcodes that end a method body (format note 8).
static bool v2_is_terminator(int op) {
  switch (op) {
    case RETURN:
    case RETURN_NULL:
    case THROW:
    case BRANCH:
    case BRANCH_BACK:
    case INVOKE_STATIC_TAIL:
    case INVOKE_LAMBDA_TAIL:
    case INVOKE_INITIALIZER_TAIL:
    case NON_LOCAL_RETURN:
    case NON_LOCAL_BRANCH:
      return true;
    default:
      return false;
  }
}

// The branch opcodes of format 2: four forward, then four backward ones.
static const int V2_FIRST_BRANCH = 81;
static const int V2_FIRST_BRANCH_BACK = 85;
static const int V2_LAST_BRANCH = 88;

// Opcode numbers that format 2 reuses (src/compiler/bytecode_format.h).
static const int V2_STORE_FIELD_THIS = NON_LOCAL_RETURN_WIDE;
static const int V2_LOAD_FIELD_THIS = UNLINK;

static bool v2_read_leb(const uint8* bytes, word length, word* at, uint32* result) {
  uint32 value = 0;
  for (int i = 0; i < V2_MAX_LEB_BYTES; i++) {
    if (*at >= length) return false;
    uint8 byte = bytes[(*at)++];
    value |= static_cast<uint32>(byte & 0x7f) << (7 * i);
    if ((byte & 0x80) == 0) {
      if (byte == 0 && i > 0) return false;  // Not in its shortest form.
      *result = value;
      return true;
    }
  }
  return false;
}

static V2MethodTable* v2_fail(const char* message, word detail = -1) {
  if (detail >= 0) {
    fprintf(stderr, "format-2 program rejected: %s (%" PRIdPTR ")\n", message, detail);
  } else {
    fprintf(stderr, "format-2 program rejected: %s\n", message);
  }
  return null;
}

V2MethodTable::~V2MethodTable() {
  free(methods_);
}

V2MethodTable* V2MethodTable::compute(Program* program, bool untrusted) {
  const uint8* bytes = program->bytecodes.data();
  word length = program->bytecodes.length();
  if (!program->is_format2()) return v2_fail("missing tag");
  if (length >= V2_MAX_TABLE) return v2_fail("bytecodes too large");
  // First pass: count the methods.
  word count = 0;
  for (int pass = 0; pass < 2; pass++) {
    V2Method* methods = null;
    if (pass == 1) {
      if (count == 0 || count >= 0x1000000) return v2_fail("bad method count", count);
      methods = unvoid_cast<V2Method*>(calloc(count, sizeof(V2Method)));
      if (methods == null) return null;
    }
    word at = V2_TAG_SIZE;
    word index = 0;
    while (at < length) {
      if (at + 2 > length) { free(methods); return v2_fail("truncated method header", at); }
      uint8 arity = bytes[at];
      uint8 flags = bytes[at + 1];
      if ((flags & ~(V2_KIND_MASK | V2_HAS_SELECTOR | V2_HAS_RECEIVER)) != 0) {
        free(methods);
        return v2_fail("bad method header flags", at);
      }
      int kind = flags & V2_KIND_MASK;
      at += 2;
      uint32 body = 0;
      uint32 selector = V2_NO_VALUE;
      uint32 recv_start = V2_NO_VALUE;
      uint32 recv_end = V2_NO_VALUE;
      uint32 aux = 0;
      bool ok = v2_read_leb(bytes, length, &at, &body);
      if (ok && (flags & V2_HAS_SELECTOR) != 0) {
        ok = v2_read_leb(bytes, length, &at, &selector) && selector < V2_NO_VALUE;
      }
      if (ok && (flags & V2_HAS_RECEIVER) != 0) {
        uint32 size = 0;
        ok = v2_read_leb(bytes, length, &at, &recv_start) &&
             v2_read_leb(bytes, length, &at, &size) &&
             size != 0 && recv_start + size <= V2_NO_VALUE;
        recv_end = recv_start + size;
      }
      if (ok && (kind == V2_KIND_FIELD_ACCESSOR || kind == V2_KIND_LAMBDA)) {
        ok = v2_read_leb(bytes, length, &at, &aux) && aux <= 0xffff;
      }
      if (!ok) { free(methods); return v2_fail("bad method header", at); }
      word entry = at;
      word end = entry + body;
      if (end > length) { free(methods); return v2_fail("truncated method body", at); }
      if (pass == 1) {
        V2Method* m = &methods[index];
        m->entry = entry;
        m->end = end;
        m->selector = selector;
        m->aux = aux;
        m->recv_start = recv_start;
        m->recv_end = recv_end;
        m->arity = arity;
        m->kind = kind;
      }
      index++;
      at = end;
    }
    if (pass == 0) {
      count = index;
      continue;
    }
    V2MethodTable* table = _new V2MethodTable(methods, count);
    if (table == null) {
      free(methods);
      return null;
    }
    // Table checks (loader.rs, check_tables_v2).
    for (word i = 0; i < program->dispatch_table.length(); i++) {
      int32 d = program->dispatch_table[i];
      if (d != -1 && !table->is_valid(d)) {
        delete table;
        return v2_fail("dispatch entry is not a method index", i);
      }
    }
    if (program->literals.length() < V2_FAILURE_LITERALS) {
      delete table;
      return v2_fail("missing failure literals");
    }
    word class_count = program->class_bits.length();
    for (word d = 0; d < program->dispatch_table.length(); d++) {
      int32 t = program->dispatch_table[d];
      if (t < 0) continue;
      const V2Method& info = table->at(t);
      if (info.selector == V2_NO_VALUE || info.recv_start == V2_NO_VALUE) continue;
      word cl = d - info.selector;
      if (0 <= cl && cl < class_count && !(info.recv_start <= cl && cl < info.recv_end)) {
        delete table;
        return v2_fail("dispatch entry outside the receiver range of its method", d);
      }
    }
    for (word m = 0; m < count; m++) {
      const V2Method& info = table->at(m);
      word bci = info.entry;
      int last = -1;
      while (bci < static_cast<word>(info.end)) {
        int op = bytes[bci];
        last = op;
        if (op >= V2_OPCODE_COUNT) {
          delete table;
          return v2_fail("bad opcode", bci);
        }
        if (bci + V2_OPCODE_LENGTHS[op] > static_cast<word>(info.end)) break;
        if (op == V2_LOAD_FIELD_THIS || op == V2_STORE_FIELD_THIS) {
          word f = bytes[bci + 1];
          if (info.recv_start == V2_NO_VALUE) {
            delete table;
            return v2_fail("this-field access without a receiver range", m);
          }
          word limit = Utils::min(static_cast<word>(info.recv_end), class_count);
          for (word cl = info.recv_start; cl < limit; cl++) {
            word fields = ((program->class_bits[cl] >> 5) & 0x7ff) - 1;
            if (f >= fields) {
              delete table;
              return v2_fail("this-field access outside the receiver's fields", m);
            }
          }
        }
        if (V2_FIRST_BRANCH <= op && op <= V2_LAST_BRANCH) {
          // Branch targets stay inside the method (format note 9); the core
          // checks them again at run time.
          // A backward branch may target itself (an empty loop).
          word offset = bytes[bci + 1] | (bytes[bci + 2] << 8);
          if (offset == 0 && op < V2_FIRST_BRANCH_BACK) {
            delete table;
            return v2_fail("branch with zero offset", bci);
          }
          word target = op < V2_FIRST_BRANCH_BACK ? bci + offset : bci - offset;
          if (target < static_cast<word>(info.entry) || target >= static_cast<word>(info.end)) {
            delete table;
            return v2_fail("branch target outside the method", bci);
          }
        }
        if (untrusted && op == HALT && bytes[bci + 1] >= 2) {
          delete table;
          return v2_fail("HALT 2 and HALT 3 are not allowed in untrusted programs", bci);
        }
        bci += V2_OPCODE_LENGTHS[op];
      }
      if (bci != static_cast<word>(info.end)) {
        delete table;
        return v2_fail("the last instruction crosses the end of method", m);
      }
      if (!v2_is_terminator(last)) {
        delete table;
        return v2_fail("method does not end in a terminator", m);
      }
    }
    return table;
  }
  UNREACHABLE();
}

bool V2MethodTable::untrusted_format1_allowed() {
  if (Flags::untrusted_format1) return true;
  const char* env = getenv("TOIT_UNTRUSTED_FORMAT1");
  return env != null && strcmp(env, "1") == 0;
}

bool V2MethodTable::verify(Program* program, bool untrusted) {
  V2MethodTable* table = compute(program, untrusted);
  if (table == null) return false;
  delete table;
  return true;
}

word V2MethodTable::entry_method(Program* program, int entry_point_index) const {
  int d = program->entry_point_indexes()[entry_point_index];
  if (d < 0 || d >= program->dispatch_table.length()) return -1;
  word m = program->dispatch_table[d];
  return is_valid(m) ? m : -1;
}

word V2MethodTable::index_of_entry(word entry) const {
  word low = 0;
  word high = length_ - 1;
  while (low <= high) {
    word mid = low + (high - low) / 2;
    word e = methods_[mid].entry;
    if (e == entry) return mid;
    if (e < entry) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return -1;
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
  stack->v2_word_at_put(Stack::V2_FRAME_RET, table->at(entry).entry);
  stack->v2_word_at_put(Stack::V2_FRAME_BASE, 0);
  stack->v2_word_at_put(Stack::V2_FRAME_HANDLER, 0);
  stack->v2_set_frame_top(Stack::V2_FRAME_WORDS);
  stack->v2_set_bci(table->at(entry).entry);
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
  word e = table->at(entry).entry;
  to_stack->v2_word_at_put(Stack::V2_FRAME_METHOD, entry);
  to_stack->v2_word_at_put(Stack::V2_FRAME_RET, e);
  to_stack->v2_word_at_put(Stack::V2_FRAME_BASE, 0);
  to_stack->v2_word_at_put(Stack::V2_FRAME_HANDLER, 0);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_METHOD, method);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_RET, e + 1);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_BASE, 1);
  to_stack->v2_word_at_put(Stack::V2_FRAME_WORDS + Stack::V2_FRAME_HANDLER, 0);
  to_stack->v2_set_frame_top(2 * Stack::V2_FRAME_WORDS);
  to_stack->v2_set_bci(from_stack->v2_bci());
  GcMetadata::insert_into_remembered_set(to_stack);
  return true;
}

// `core.task_transfer` for format 2. The core has stored the running task's
// state into its stack before the call; after it, the core continues with
// whatever task is current, after its PRIMITIVE with [to] pushed (the
// failure path, as in format 1).
Object* Interpreter::v2_task_transfer(Process* process, Task* to, bool detach_stack) {
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

Interpreter::Result Interpreter::run_v2() {
#ifdef TOIT_VERIFIED_CORE
  process_->object_heap()->leave_primitive();
  preemption_method_header_bcp_ = null;
  Program* program = process_->program();
  const V2MethodTable* table = v2_table(process_);
  toit_v2_context context;
  memset(&context, 0, sizeof(context));
  context.process = process_;
  toit_v2_program* p = &context.program;
  p->bytecodes = program->bytecodes.data();
  p->bytecodes_length = program->bytecodes.length();
  p->methods = table->methods();
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
  p->globals = reinterpret_cast<uword*>(process_->object_heap()->global_variables());
  p->globals_length = program->global_variables.length();
  p->program_heap_start = reinterpret_cast<uword>(program);
  p->program_heap_size = program->size_no_assets();
  p->remembered_set_bias = GcMetadata::remembered_set_bias();
  p->global_max_height = program->global_max_stack_height();
  p->stack_array_word = Stack::v2_array_word();
  context.watermark = &watermark_;
  context.preempt_a_lot = Flags::preempt_a_lot ? 1 : 0;

  v2_validate(process_, "run entry");
  toit_v2_run(&context);
  v2_validate(process_, "run exit");

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

}  // namespace toit

// --------------------------------------------------------------------------
// The functions the core calls.

using namespace toit;

static Process* v2_process(void* process) {
  return static_cast<Process*>(process);
}

// Debugging aid (TOIT_V2_VALIDATE=1): checks that every object-stack slot
// of the current task is a smi or points to something with a plausible
// header.
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
      fprintf(stderr, "v2_validate(%s, %s stack %p): bad slot %ld (position %ld) = %p header %p; top %ld length %ld frame top %ld bci %ld\n",
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

// As Interpreter::gc, without moving the interpreter's stack pointers (the
// core has stored its state into the stack object).
static void v2_gc(Process* process, bool malloc_failed, int attempts, bool force_cross_process,
                  const char* reason, word parameter1 = 0, word parameter2 = 0) {
  if (attempts == 3) {
    static const int BUFFER_SIZE = 50;
    char buffer[BUFFER_SIZE];
    snprintf(buffer, BUFFER_SIZE, "out of memory in %s %" PRIdPTR ":%" PRIdPTR,
             reason, parameter1, parameter2);
    buffer[BUFFER_SIZE - 1] = '\0';
    OS::heap_summary_report(0, buffer, process);
    if (VM::current()->scheduler()->is_boot_process(process)) {
      OS::out_of_memory("Out of memory in system process");
    }
    return;
  }
  GcMetadata::insert_into_remembered_set(process->task()->stack());
  v2_validate(process, "gc");
  VM::current()->scheduler()->gc(process, malloc_failed, attempts > 1 || force_cross_process);
  v2_validate(process, "after gc");
}

template <typename F>
static uword v2_allocate(Process* process, const char* reason, F allocate) {
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

uword toit_v2_current_stack(void* process) {
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
  Stack* stack = process->task()->stack();
  // The core has written into the stack since it was last remembered. The
  // old stack becomes garbage, but the collector still scans it whenever
  // its card is dirty (old space is swept, not traced, between scavenges),
  // so its new-space pointers must stay up to date: remember it now, as
  // Interpreter::store_stack does for format 1.
  GcMetadata::insert_into_remembered_set(stack);
  word length = stack->length();
  word free = stack->top() - stack->v2_frame_top();
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

uword toit_v2_lookup_primitive(void* raw_process, uword module, uword index,
                               const void** entry, uword* arity) {
  Process* process = v2_process(raw_process);
  const PrimitiveEntry* primitive = process->policy()->at(module, index);
  if (Flags::primitives) printf("[invoking primitive %d::%d]\n", static_cast<int>(module), static_cast<int>(index));
  if (primitive == null) return TOIT_V2_PRIMITIVE_MISSING;
  *entry = primitive;
  *arity = primitive->arity;
  return TOIT_V2_PRIMITIVE_FOUND;
}

uword toit_v2_call_primitive(void* raw_process, const void* raw_entry, uword arity,
                             uword first_argument, uword* result_out) {
  Process* process = v2_process(raw_process);
  Program* program = process->program();
  const PrimitiveEntry* primitive = static_cast<const PrimitiveEntry*>(raw_entry);
  Primitive::Entry* entry = reinterpret_cast<Primitive::Entry*>(primitive->function);
  GcMetadata::insert_into_remembered_set(process->task()->stack());
  v2_validate(process, "primitive entry");
  Stack* stack = process->task()->stack();
  Object* result = entry(process, stack->v2_slot_address(first_argument));
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
    v2_gc(process, malloc_failed, attempts, force_cross_process, "primitive");
    stack = process->task()->stack();
    result = entry(process, stack->v2_slot_address(first_argument));
  }
  process->object_heap()->leave_primitive();
  *result_out = reinterpret_cast<uword>(result);
  return TOIT_V2_PRIMITIVE_FAILURE;
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
  }
}

}  // extern "C"

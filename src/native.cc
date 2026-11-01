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

#include "native.h"

#include "bytecodes.h"
#include "primitive.h"
#include "scheduler.h"
#include "vm.h"

#include <math.h>

namespace toit {

static const NativeProgram* registered_program = null;

static Method find_method(Program* program, Object* receiver, word offset) {
  Smi* class_id = is_smi(receiver) ? program->smi_class_id() : HeapObject::cast(receiver)->class_id();
  int entry_id = program->dispatch_table[Smi::value(class_id) + offset];
  if (entry_id == -1) return Method::invalid();
  Method entry(program->bytecodes, entry_id);
  if (entry.selector_offset() != offset) return Method::invalid();
  return entry;
}

int NativeRuntime::register_program(const NativeProgram* program) {
  registered_program = program;
  Interpreter::set_native_runner(&NativeRuntime::run, &NativeRuntime::start_address);
  Stack::set_native_return_bci(&NativeRuntime::return_bci);
  return 0;
}

static bool matches_registered_program(Program* program) {
  static Program* last_matching = null;
  static Program* last_different = null;
  if (program == last_matching) return true;
  if (program == last_different) return false;
  word length = program->bytecodes.length();
  bool matches = length == registered_program->bytecodes_length &&
      native_fingerprint(program->bytecodes.data(), length) == registered_program->fingerprint;
  (matches ? last_matching : last_different) = program;
  return matches;
}

NativeFn NativeRuntime::find_entry(const NativeProgram* native, int bci) {
  const NativeEntry* entries = native->entries;
  int low = 0;
  int high = native->entry_count - 1;
  while (low <= high) {
    int middle = low + (high - low) / 2;
    int probe = entries[middle].bci;
    if (probe == bci) return entries[middle].fn;
    if (probe < bci) {
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  FATAL("no native code at %d", bci);
}

// Processes and tasks are set up with the addresses they start from
// and that entry methods return to, so native code never sees bytecodes.
Object* NativeRuntime::start_address(Program* program, uint8* bcp) {
  if (!matches_registered_program(program)) return reinterpret_cast<Object*>(bcp);
  int bci = program->absolute_bci_from_bcp(bcp);
  return reinterpret_cast<Object*>(find_entry(registered_program, bci));
}

// Translates the addresses found in frames on the stack to
// the bcis the interpreter would have found in the same frames.
int NativeRuntime::return_bci(Program* program, uint8* address) {
  if (!matches_registered_program(program)) return program->absolute_bci_from_bcp(address);
  NativeFn fn = reinterpret_cast<NativeFn>(address);
  const NativeProgram* native = registered_program;
  for (int i = 0; i < native->return_count; i++) {
    if (native->returns[i].fn == fn) return native->returns[i].bci;
  }
  for (int i = 0; i < native->entry_count; i++) {
    if (native->entries[i].fn == fn) return native->entries[i].bci;
  }
  return -1;
}

bool NativeRuntime::run(Interpreter* interpreter, Interpreter::Result* result) {
  Process* process = interpreter->process_;
  Program* program = process->program();
  if (!matches_registered_program(program)) return false;
  NativeContext context = {
    .interpreter = interpreter,
    .process = process,
    .program = program,
    .native = registered_program,
    .null_object = program->null_object(),
    .true_object = program->true_object(),
    .false_object = program->false_object(),
    .frame_marker = program->frame_marker(),
    .literals = program->literals.array(),
    .globals = process->object_heap()->global_variables(),
    .result = Interpreter::Result(Interpreter::Result::PREEMPTED),
  };
  interpreter->preemption_method_header_bcp_ = null;
  Object** sp = interpreter->load_stack();
  POP();  // Frame marker.
  Object* address = POP();
  reinterpret_cast<NativeFn>(address)(sp, &context, null, 0);
  *result = context.result;
  return true;
}

#define CALL(target)                                                  \
  do {                                                                \
    Method _target_ = (target);                                       \
    PUSH(reinterpret_cast<Object*>(x));                               \
    PUSH(c->frame_marker);                                            \
    int _bci_ = c->program->absolute_bci_from_bcp(_target_.entry());  \
    NATIVE_TAIL find_entry(c->native, _bci_)(sp, c, null, 0);                 \
  } while (false)

#define CONTINUE() NATIVE_TAIL reinterpret_cast<NativeFn>(x)(sp, c, null, 0)

void NativeRuntime::stack_overflow(NATIVE_PARAMS) {
  Interpreter* interpreter = c->interpreter;
  Method target(c->program->bytecodes, y);
  Interpreter::OverflowState state;
  sp = interpreter->handle_stack_overflow(sp, &state, target);
  switch (state) {
    case Interpreter::OVERFLOW_RESUME:
      // Enter the method again, so we get the check done again.
      CONTINUE();
    case Interpreter::OVERFLOW_PREEMPT:
      interpreter->preemption_method_header_bcp_ = target.header_bcp();
      PUSH(reinterpret_cast<Object*>(x));
      PUSH(c->frame_marker);
      interpreter->store_stack(sp);
      c->result = Interpreter::Result(Interpreter::Result::PREEMPTED);
      return;
    case Interpreter::OVERFLOW_EXCEPTION:
      break;
  }
  NATIVE_TAIL throw_exception(sp, c, null, 0);
}

void NativeRuntime::preempt(NATIVE_PARAMS) {
  Interpreter* interpreter = c->interpreter;
  interpreter->watermark_ = null;
  uint8* entry = c->program->bcp_from_absolute_bci(y);
  interpreter->preemption_method_header_bcp_ = Method::header_from_entry(entry);
  PUSH(reinterpret_cast<Object*>(x));
  PUSH(c->frame_marker);
  interpreter->store_stack(sp);
  c->result = Interpreter::Result(Interpreter::Result::PREEMPTED);
}

void NativeRuntime::primitive(NATIVE_PARAMS) {
  Interpreter* interpreter = c->interpreter;
  Process* process = c->process;
  Program* program = c->program;
  int module = y >> 16;
  int index = y & 0xffff;
  const PrimitiveEntry* entry = Primitive::at(module, index);
  if (entry == null) {
    PUSH(Smi::from(module));
    PUSH(Smi::from(index));
    CALL(program->primitive_lookup_failure());
  }
  int arity = entry->arity;
  auto function = reinterpret_cast<Primitive::Entry*>(entry->function);
  const int parameter_offset = Interpreter::FRAME_SIZE;

  interpreter->sp_ = sp;
  Object* result = function(process, sp + parameter_offset + arity - 1);
  sp = interpreter->sp_;

  for (int attempts = 1; true; attempts++) {
    if (!Primitive::is_error(result)) {
      POP();  // Frame marker.
      Object* address = POP();
      DROP(arity);
      PUSH(result);
      process->object_heap()->leave_primitive();
      NATIVE_TAIL reinterpret_cast<NativeFn>(address)(sp, c, null, 0);
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
      sp = interpreter->push_error(sp, result, "");
      NATIVE_TAIL throw_exception(sp, c, null, 0);
    }

    sp = interpreter->gc(sp, malloc_failed, attempts, force_cross_process, "primitive", module, index);
    interpreter->sp_ = sp;
    result = function(process, sp + parameter_offset + arity - 1);
    sp = interpreter->sp_;
  }

  // The primitive failed, so we continue with the code that follows it.
  PUSH(result);
  process->object_heap()->leave_primitive();
  CONTINUE();
}

void NativeRuntime::throw_exception(NATIVE_PARAMS) {
  // The exception is already at the top of the stack.
  PUSH(to_block(c, c->interpreter->base_));
  PUSH(Smi::from(Interpreter::UNWIND_REASON_WHEN_THROWING_EXCEPTION));
  NATIVE_TAIL unwind(sp, c, x, y);
}

void NativeRuntime::unwind(NATIVE_PARAMS) {
  Interpreter* interpreter = c->interpreter;
  Object* tos = POP();
  word tos_value = Smi::value(tos);
  if (tos_value == -1) {
    // Leaving the try/finally normally.
    DROP(2);
    CONTINUE();
  }

  Object** target_sp = from_block(c, POP());
  Object* result_or_height_diff = POP();

  if (target_sp > interpreter->try_sp_) {
    // Continue as if the try-block had returned. The unwind bytecode
    // at the end of the finally code picks it up from here.
    int block_pointer_slot = 1;
    sp = interpreter->try_sp_ - block_pointer_slot - Interpreter::FRAME_SIZE;
    int link_offset = interpreter->try_sp_ - sp;
    STACK_AT_PUT(link_offset + 1, tos);
    STACK_AT_PUT(link_offset + 2, to_block(c, target_sp));
    STACK_AT_PUT(link_offset + 3, result_or_height_diff);
    POP();  // Frame marker.
    Object* address = POP();
    NATIVE_TAIL reinterpret_cast<NativeFn>(address)(sp, c, null, 0);
  } else if (tos_value == Interpreter::UNWIND_REASON_WHEN_THROWING_EXCEPTION || (tos_value & 1) == 0) {
    // An exception or a non-local return.
    word arity = (tos_value == Interpreter::UNWIND_REASON_WHEN_THROWING_EXCEPTION) ? 0 : tos_value >> 1;
    sp = target_sp;
    Object* frame_marker = POP();
    if (frame_marker != c->frame_marker) {
      FATAL("Threw exception before entering last-chance catch clause");
    }
    Object* address = POP();
    DROP(arity);
    PUSH(result_or_height_diff);
    NATIVE_TAIL reinterpret_cast<NativeFn>(address)(sp, c, null, 0);
  } else {
    // A non-local branch.
    int bci = tos_value >> 1;
    sp = target_sp;
    DROP(Smi::value(result_or_height_diff));
    NATIVE_TAIL find_entry(c->native, bci)(sp, c, null, 0);
  }
}

void NativeRuntime::non_local_return(NATIVE_PARAMS) {
  word arity = y >> 16;
  word height = y & 0xffff;
  Object* block = POP();
  Object* result = POP();
  Object** target_sp = from_block(c, block) + height + 1;
  PUSH(result);
  PUSH(to_block(c, target_sp));
  PUSH(Smi::from(arity << 1));
  NATIVE_TAIL unwind(sp, c, x, 0);
}

void NativeRuntime::non_local_branch(NATIVE_PARAMS) {
  // The target is given by the bci in x; the height difference is in y.
  word bci = reinterpret_cast<word>(x);
  Object* block = POP();
  Object** target_sp = from_block(c, block);
  PUSH(Smi::from(y));
  PUSH(to_block(c, target_sp));
  PUSH(Smi::from((bci << 1) | 1));
  NATIVE_TAIL unwind(sp, c, null, 0);
}

void NativeRuntime::allocate(NATIVE_PARAMS) {
  Interpreter* interpreter = c->interpreter;
  Process* process = c->process;
  Smi* class_index = Smi::from(y);
  Object* result = process->object_heap()->allocate_instance(class_index);
  for (int attempts = 1; result == null && attempts < 4; attempts++) {
    sp = interpreter->gc(sp, false, attempts, false, "'allocate instance'", y);
    result = process->object_heap()->allocate_instance(class_index);
  }
  process->object_heap()->leave_primitive();
  if (result == null) {
    sp = interpreter->push_error(sp, c->program->allocation_failed(), "");
    NATIVE_TAIL throw_exception(sp, c, null, 0);
  }
  PUSH(result);
  CONTINUE();
}

static bool smi_shl(Object* a, Object* b, Object** result) {
  word bits = Smi::value(b);
  if (bits < 0 || bits >= WORD_BIT_SIZE) return false;
  word shifted = reinterpret_cast<word>(a) << bits;
  if (reinterpret_cast<word>(a) != (shifted >> bits)) return false;
  *result = reinterpret_cast<Object*>(shifted);
  return true;
}

static bool smi_shr(Object* a, Object* b, Object** result) {
  word bits = Smi::value(b);
  if (bits < 0 || bits >= WORD_BIT_SIZE) return false;
  *result = Smi::from(Smi::value(a) >> bits);
  return true;
}

static bool smi_ushr(Object* a, Object* b, Object** result) {
  word bits = Smi::value(b);
  word value = Smi::value(a);
  if (bits < 0 || bits >= WORD_BIT_SIZE || value < 0) return false;
  *result = Smi::from(value >> bits);
  return true;
}

static bool are_floats(Object* a, Object* b) {
  if (is_smi(a) || is_smi(b)) return false;
  return HeapObject::cast(a)->has_class_tag(DOUBLE_TAG) && HeapObject::cast(b)->has_class_tag(DOUBLE_TAG);
}

void NativeRuntime::binary(NATIVE_PARAMS) {
  Program* program = c->program;
  Object* a0 = STACK_AT(1);
  Object* a1 = STACK_AT(0);
  Opcode opcode = static_cast<Opcode>(y);
  Object* result = null;
  bool smis = native_are_smis(a0, a1);
  word i0 = smis ? Smi::value(a0) : 0;
  word i1 = smis ? Smi::value(a1) : 0;

  auto relational = [&](bool smi_result, int flag) {
    if (smis) {
      result = program->boolean(smi_result);
    } else if (int compared = Interpreter::compare_numbers(a0, a1)) {
      result = program->boolean((compared & flag) != 0);
    }
  };

  auto floating = [&](double_op* op) {
    if (are_floats(a0, a1)) result = Interpreter::float_op(c->process, a0, a1, op);
  };

  switch (opcode) {
    case INVOKE_EQ:
      if (a0 == a1) {
        result = program->boolean(!(is_double(a0) && isnan(Double::cast(a0)->value())));
      } else if (a0 == c->null_object || a1 == c->null_object) {
        result = c->false_object;
      } else {
        relational(i0 == i1, Interpreter::COMPARE_FLAG_EQUAL);
      }
      break;
    case INVOKE_LT:
      relational(i0 < i1, Interpreter::COMPARE_FLAG_STRICTLY_LESS);
      break;
    case INVOKE_LTE:
      relational(i0 <= i1, Interpreter::COMPARE_FLAG_LESS_EQUAL);
      break;
    case INVOKE_GT:
      relational(i0 > i1, Interpreter::COMPARE_FLAG_STRICTLY_GREATER);
      break;
    case INVOKE_GTE:
      relational(i0 >= i1, Interpreter::COMPARE_FLAG_GREATER_EQUAL);
      break;
    case INVOKE_BIT_OR:
      if (smis) result = Smi::from(i0 | i1);
      break;
    case INVOKE_BIT_XOR:
      if (smis) result = Smi::from(i0 ^ i1);
      break;
    case INVOKE_BIT_AND:
      if (smis) result = Smi::from(i0 & i1);
      break;
    case INVOKE_DIV:
      if (smis && i1 != 0) result = Smi::from(i0 / i1);
      break;
    case INVOKE_MOD:
      if (smis && i1 != 0) result = Smi::from(i0 % i1);
      break;
    case INVOKE_ADD:
      if (!(smis && native_add(a0, a1, &result))) floating(&double_add);
      break;
    case INVOKE_SUB:
      if (!(smis && native_sub(a0, a1, &result))) floating(&double_sub);
      break;
    case INVOKE_MUL:
      if (!(smis && native_mul(a0, a1, &result))) floating(&double_mul);
      break;
    case INVOKE_BIT_SHL:
      if (smis && !smi_shl(a0, a1, &result)) result = null;
      break;
    case INVOKE_BIT_SHR:
      if (smis && !smi_shr(a0, a1, &result)) result = null;
      break;
    case INVOKE_BIT_USHR:
      if (smis && !smi_ushr(a0, a1, &result)) result = null;
      break;
    default:
      UNREACHABLE();
  }

  if (result != null) {
    STACK_AT_PUT(1, result);
    DROP(1);
    CONTINUE();
  }
  y = program->invoke_bytecode_offset(opcode) << 8 | 1;
  NATIVE_TAIL virtual_fallback(NATIVE_ARGS);
}

void NativeRuntime::at(NATIVE_PARAMS) {
  Object* value = null;
  if (Interpreter::fast_at(c->process, STACK_AT(1), STACK_AT(0), false, &value)) {
    STACK_AT_PUT(1, value);
    DROP(1);
    CONTINUE();
  }
  y = c->program->invoke_bytecode_offset(INVOKE_AT) << 8 | 1;
  NATIVE_TAIL virtual_fallback(NATIVE_ARGS);
}

void NativeRuntime::at_put(NATIVE_PARAMS) {
  Object* value = STACK_AT(0);
  if (Interpreter::fast_at(c->process, STACK_AT(2), STACK_AT(1), true, &value)) {
    STACK_AT_PUT(2, value);
    DROP(2);
    CONTINUE();
  }
  y = c->program->invoke_bytecode_offset(INVOKE_AT_PUT) << 8 | 2;
  NATIVE_TAIL virtual_fallback(NATIVE_ARGS);
}

void NativeRuntime::size(NATIVE_PARAMS) {
  Smi* result;
  if (Interpreter::fast_size(c->process, STACK_AT(0), &result)) {
    STACK_AT_PUT(0, result);
    CONTINUE();
  }
  y = y << 8;
  NATIVE_TAIL virtual_fallback(NATIVE_ARGS);
}

// The selector offset is in the upper bits of y and the
// stack offset of the receiver is in the lower 8 bits.
void NativeRuntime::virtual_fallback(NATIVE_PARAMS) {
  Program* program = c->program;
  word offset = y >> 8;
  Object* receiver = STACK_AT(y & 0xff);
  Method target = find_method(program, receiver, offset);
  if (!target.is_valid()) {
    PUSH(receiver);
    PUSH(Smi::from(offset));
    target = program->lookup_failure();
  }
  CALL(target);
}

// The value is on the stack and the bci to report is in y.
void NativeRuntime::as_failure(NATIVE_PARAMS) {
  PUSH(Smi::from(y));
  CALL(c->program->as_check_failure());
}

void NativeRuntime::code_failure(NATIVE_PARAMS) {
  CALL(c->program->code_failure());
}

void NativeRuntime::program_failure(NATIVE_PARAMS) {
  PUSH(Smi::from(y));
  CALL(c->program->program_failure());
}

void NativeRuntime::primitive_failure(NATIVE_PARAMS) {
  CALL(c->program->primitive_lookup_failure());
}

// The number of arguments on the stack is in y.
void NativeRuntime::lambda_tail(NATIVE_PARAMS) {
  Program* program = c->program;
  word bci_offset = y;
  Instance* receiver = Instance::cast(STACK_AT(bci_offset + Interpreter::FRAME_SIZE));
  Method target(program->bytecodes, Smi::value(receiver->at(0)));
  int captured_size = 1;
  Object* argument = receiver->at(1);
  if (is_array(argument)) captured_size = Array::cast(argument)->length();
  int user_arity = target.arity() - captured_size;
  if (bci_offset < user_arity) {
    PUSH(c->false_object);  // It's not a block.
    PUSH(Smi::from(user_arity));
    PUSH(Smi::from(bci_offset));
    PUSH(Smi::from(program->absolute_bci_from_bcp(target.entry())));
    NATIVE_TAIL code_failure(NATIVE_ARGS);
  }
  POP();  // Frame marker.
  x = reinterpret_cast<void*>(POP());
  // Get rid of the receiver and the arguments that are too many.
  word extra = bci_offset - user_arity;
  for (word i = bci_offset; i > extra; i--) STACK_AT_PUT(i, STACK_AT(i - 1));
  DROP(extra + 1);
  if (is_array(argument)) {
    Array* arguments = Array::cast(argument);
    for (int i = 0; i < captured_size; i++) PUSH(arguments->at(i));
  } else {
    PUSH(argument);
  }
  CALL(target);
}

// The height is in the lower 16 bits of y and the arity is in the upper bits.
void NativeRuntime::initializer_tail(NATIVE_PARAMS) {
  Program* program = c->program;
  word height = (y & 0xffff) - 1;
  word outer_arity = y >> 16;
  Object* method_id = POP();
  Method target(program->bytecodes, Smi::value(method_id));
  word call_arity = target.arity();
  if (call_arity != 0) {
    PUSH(Smi::from(0));
    CALL(program->program_failure());
  }
  x = reinterpret_cast<void*>(STACK_AT(height + 1));
  DROP(height + Interpreter::FRAME_SIZE + outer_arity);
  CALL(target);
}

void NativeRuntime::load_global_dynamic(NATIVE_PARAMS) {
  word index = Smi::value(POP());
  if (!(0 <= index && index < c->program->global_variables.length())) {
    NATIVE_TAIL program_failure(NATIVE_ARGS);
  }
  PUSH(c->globals[index]);
  CONTINUE();
}

void NativeRuntime::store_global_dynamic(NATIVE_PARAMS) {
  Object* value = POP();
  word index = Smi::value(POP());
  if (!(0 <= index && index < c->program->global_variables.length())) {
    NATIVE_TAIL program_failure(NATIVE_ARGS);
  }
  c->globals[index] = value;
  CONTINUE();
}

void NativeRuntime::halt(NATIVE_PARAMS) {
  Interpreter* interpreter = c->interpreter;
  if (y == 0) {
    // Push a return value for when we resume from yield.
    PUSH(Smi::from(91));
    PUSH(reinterpret_cast<Object*>(x));
    PUSH(c->frame_marker);
    interpreter->store_stack(sp);
    c->result = Interpreter::Result(Interpreter::Result::YIELDED);
  } else if (y == 1) {
    int exit_value = Smi::value(POP());
    PUSH(reinterpret_cast<Object*>(x));
    PUSH(c->frame_marker);
    interpreter->store_stack(sp);
    c->result = Interpreter::Result(exit_value);
  } else if (y == 2) {
    Object* duration = POP();
    int64 value = 0;
    if (is_smi(duration)) {
      value = Smi::value(duration);
    } else if (is_large_integer(duration)) {
      value = LargeInteger::cast(duration)->value();
    } else {
      FATAL("Cannot handle non-numeric deep sleep argument");
    }
    PUSH(reinterpret_cast<Object*>(x));
    PUSH(c->frame_marker);
    interpreter->store_stack(sp);
    c->result = Interpreter::Result(Interpreter::Result::DEEP_SLEEP, value);
  } else {
    PUSH(reinterpret_cast<Object*>(x));
    PUSH(c->frame_marker);
    interpreter->store_stack(sp);
    c->result = Interpreter::Result(Interpreter::Result::RESET);
  }
}

// These intrinsics are loops. The block returns to the intrinsic itself,
// which is in x. If the block takes too many arguments, it fails when it
// is called, so we don't need to look at the code that follows the intrinsic.
void NativeRuntime::smi_repeat(NATIVE_PARAMS) {
  DROP(1);  // Drop last result of calling the block (or initial discardable value).
  Object* current = STACK_AT(0);
  int parameter_offset = 1 + Interpreter::FRAME_SIZE;
  Object* block = STACK_AT(parameter_offset + 0);
  word end = Smi::value(STACK_AT(parameter_offset + 1));
  if (Smi::value(current) >= end) {
    DROP(1);
    POP();  // Frame marker.
    NativeFn next = reinterpret_cast<NativeFn>(POP());
    DROP(1);
    STACK_AT_PUT(0, c->null_object);
    NATIVE_TAIL next(sp, c, null, 0);
  }
  STACK_AT_PUT(0, Smi::from(Smi::value(current) + 1));
  PUSH(block);
  PUSH(current);
  NATIVE_TAIL reinterpret_cast<NativeFn>(*from_block(c, block))(sp, c, x, 2);
}

void NativeRuntime::array_do(NATIVE_PARAMS) {
  DROP(1);  // Drop last result of calling the block (or initial discardable value).
  word current = Smi::value(STACK_AT(0));
  int parameter_offset = 1 + Interpreter::FRAME_SIZE;
  Object* block = STACK_AT(parameter_offset + 0);
  word end = Smi::value(STACK_AT(parameter_offset + 1));
  Array* backing = Array::cast(STACK_AT(parameter_offset + 2));
  if (current >= end) {
    DROP(1);
    POP();  // Frame marker.
    NativeFn next = reinterpret_cast<NativeFn>(POP());
    DROP(2);
    STACK_AT_PUT(0, c->null_object);
    NATIVE_TAIL next(sp, c, null, 0);
  }
  STACK_AT_PUT(0, Smi::from(current + 1));
  PUSH(block);
  PUSH(backing->at(current));
  NATIVE_TAIL reinterpret_cast<NativeFn>(*from_block(c, block))(sp, c, x, 2);
}

void NativeRuntime::illegal(NATIVE_PARAMS) {
  FATAL("illegal native code reached");
}

Object* NativeRuntime::identical(NativeContext* c, Object* a0, Object* a1) {
  Program* program = c->program;
  if (a0 == a1) return c->true_object;
  if (is_double(a0) && is_double(a1)) {
    return program->boolean(Double::cast(a0)->bits() == Double::cast(a1)->bits());
  }
  if (is_large_integer(a0) && is_large_integer(a1)) {
    return program->boolean(LargeInteger::cast(a0)->value() == LargeInteger::cast(a1)->value());
  }
  if (is_string(a0) && is_string(a1)) {
    return program->boolean(String::cast(a0)->compare(String::cast(a1)) == 0);
  }
  return c->false_object;
}

bool NativeRuntime::is_interface(NativeContext* c, Object* value, word offset) {
  return find_method(c->program, value, offset).is_valid();
}

}  // namespace toit

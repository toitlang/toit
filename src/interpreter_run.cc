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

#include <math.h>

#include "flags.h"
#include "printing.h"
#include "process.h"
#include "scheduler.h"
#include "vm.h"

#include "objects_inline.h"

#ifdef TOIT_CHECK_PROPAGATED_TYPES
#include "compiler/propagation/type_database.h"
#endif

namespace toit {

inline bool are_smis(Object* a, Object* b) {
  uword bits = reinterpret_cast<uword>(a) | reinterpret_cast<uword>(b);
  bool result = is_smi(reinterpret_cast<Object*>(bits));
  // The or-trick only works if smis are tagged with a zero-bit.
  // The following ASSERT makes sure we catch any change to this scheme.
  ASSERT(!result || (is_smi(a) && is_smi(b)));
  return result;
}

inline bool Interpreter::is_true_value(Program* program, Object* value) const {
  // Only false and null are considered false values.
  if (value == program->false_object()) return false;
  if (value == program->null_object()) return false;
  return true;
}

inline bool Interpreter::typecheck_class(Program* program,
                                         Object* value,
                                         int class_index,
                                         bool is_nullable) const {
  if (is_nullable && value == program->null_object()) {
    return true;
  } else {
    Smi* class_id = is_smi(value)
        ? program->smi_class_id()
        : HeapObject::cast(value)->class_id();
    int value_class_id = class_id->value();
    int start_id = program->class_check_ids[2 * class_index];
    int end_id = program->class_check_ids[2 * class_index + 1];
    return start_id <= value_class_id && value_class_id < end_id;
  }
}

inline bool Interpreter::typecheck_interface(Program* program,
                                             Object* value,
                                             int interface_selector_index,
                                             bool is_nullable) const {
  if (is_nullable && value == program->null_object()) return true;
  int selector_offset = program->interface_check_offsets[interface_selector_index];
  Method target = program->find_method(value, selector_offset);
  return target.is_valid();
}

Method Program::find_method(Object* receiver, int offset) {
  Smi* class_id = is_smi(receiver) ? smi_class_id() : HeapObject::cast(receiver)->class_id();
  int index = class_id->value() + offset;
  int entry_id = dispatch_table[index];
  if (entry_id == -1) return Method::invalid();
  Method entry(bytecodes, entry_id);
  if (entry.selector_offset() != offset) return Method::invalid();
  return entry;
}

// OPCODE_TRACE is only called from within Interpreter::run which gives access to:
//   uint8* bcp;
#define OPCODE_TRACE() \
  if (Flags::trace) trace(bcp);

// Dispatching helper macros.
#define DISPATCH(n)                                                                \
    { ASSERT(program->bytecodes.data() <= bcp + n);                                \
      ASSERT(bcp + n < program->bytecodes.data() + program->bytecodes.length());   \
      Opcode next = static_cast<Opcode>(bcp[n]);                                   \
      bcp += n;                                                                    \
      OPCODE_TRACE()                                                               \
      goto *dispatch_table[next];                                                  \
    }
#define DISPATCH_TO(opcode)                                 \
    goto interpret_##opcode

// Opcode definition macros.
#define OPCODE_BEGIN(opcode)                                \
  interpret_##opcode: {                                     \
    static const int _length_ = opcode##_LENGTH

#define OPCODE_END()                                        \
    DISPATCH(_length_);                                     \
  }

// Definition of byte code with wide variant.
#define OPCODE_BEGIN_WITH_WIDE(opcode, arg) {               \
  uword arg;                                                \
  int _length_;                                             \
  interpret_##opcode##_WIDE:                                \
    _length_ = opcode##_WIDE_LENGTH;                        \
    arg = Utils::read_unaligned_uint16(bcp + 1);            \
    goto interpret_##opcode##_impl;                         \
  interpret_##opcode:                                       \
    _length_ = opcode##_LENGTH;                             \
    arg = bcp[1];                                           \
  interpret_##opcode##_impl:

#define PUSH(o)            ({ Object* _o_ = o; *(--sp) = _o_; })
#define POP()              (*(sp++))
#define DROP1()            (sp++)
#define DROP(n)            ({ int _n_ = n; sp += _n_; })
#define STACK_AT(n)        ({ int _n_ = n; (*(sp + _n_)); })
#define STACK_AT_PUT(n, o) ({ int _n_ = n; Object* _o_ = o; *(sp + _n_) = _o_; })

#define STACK_MOVE(to, from, amount) \
    ({ int _to_ = to; int _from_ = from; int _amount_ = amount; \
       memmove(sp + _to_ - _amount_, sp + _from_ - _amount_, amount * sizeof(Object*)); })

#define B_ARG1(name) uint8 name = bcp[1];
#define S_ARG1(name) uint16 name = Utils::read_unaligned_uint16(bcp + 1);

// CHECK_STACK_OVERFLOW checks if there is enough stack space to call
// the given target method.
#define CHECK_STACK_OVERFLOW(target)                                  \
  if (sp - target.max_height() < watermark_) {                        \
    OverflowState state;                                              \
    sp = handle_stack_overflow(sp, &state, target);                   \
    switch (state) {                                                  \
      case OVERFLOW_RESUME:                                           \
        break;                                                        \
      case OVERFLOW_PREEMPT:                                          \
        preemption_method_header_bcp_ = target.header_bcp();          \
        static_assert(FRAME_SIZE == 2, "Unexpected frame size");      \
        PUSH(reinterpret_cast<Object*>(target.entry()));              \
        PUSH(program->frame_marker());                                \
        store_stack(sp, target);                                      \
        return Result(Result::PREEMPTED);                             \
      case OVERFLOW_EXCEPTION:                                        \
        goto THROW_IMPLEMENTATION;                                    \
    }                                                                 \
  }

// CHECK_PREEMPT checks for preemption by looking at the watermark.
#define CHECK_PREEMPT(entry)                                          \
  if (watermark_ == PREEMPTION_MARKER) {                              \
    watermark_ = null;                                                \
    preemption_method_header_bcp_ = Method::header_from_entry(entry); \
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");          \
    PUSH(reinterpret_cast<Object*>(bcp));                             \
    PUSH(program->frame_marker());                                    \
    store_stack(sp);                                                  \
    return Result(Result::PREEMPTED);                                 \
  }

#ifdef TOIT_CHECK_PROPAGATED_TYPES
#define CHECK_PROPAGATED_TYPES_METHOD_ENTRY(target) \
  if (propagated_types) propagated_types->check_method_entry(target, sp);
#else
#define CHECK_PROPAGATED_TYPES_METHOD_ENTRY(target)
#endif

#define CALL_METHOD_WITH_RETURN_ADDRESS(target, return_address)       \
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");            \
  PUSH(reinterpret_cast<Object*>(return_address));                    \
  PUSH(program->frame_marker());                                      \
  CHECK_STACK_OVERFLOW(target)                                        \
  CHECK_PROPAGATED_TYPES_METHOD_ENTRY(target);                        \
  bcp = target.entry();                                               \
  DISPATCH(0)

#define CALL_METHOD(target, offset)                                   \
  CALL_METHOD_WITH_RETURN_ADDRESS(target, bcp + offset)

inline word bit_or(word a, word b) { return a | b; }
inline word bit_xor(word a, word b) { return a ^ b; }
inline word bit_and(word a, word b) { return a & b; }
inline word add(word a, word b) { return a + b; }
inline word sub(word a, word b) { return a - b; }
inline word mul(word a, word b) { return a * b; }

// Returns false if not smis or overflow.
inline bool intrinsic_add(Object* a, Object* b, Smi** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_sadd_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result);
#endif
}

// Returns false if not smis or overflow.
inline bool intrinsic_sub(Object* a, Object* b, Smi** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_ssub_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result);
#endif
}

// Returns false if not smis or overflow.
inline bool intrinsic_mul(Object* a, Object* b, Smi** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_smul_overflow((word) a, ((word) b) >> 1, (word*) result);
#elif BUILD_64
    !LP64(__builtin_smul,_overflow)((word) a, ((word) b) >> 1, (word*) result);
#endif
}

inline bool intrinsic_shl(Object* a, Object* b, Smi** result) {
  if (!are_smis(a, b)) return false;
  word bits_to_shift = Smi::cast(b)->value();
  if (bits_to_shift < 0 || bits_to_shift >= WORD_BIT_SIZE) return false;
  *result = (Smi*) (((word) a) << bits_to_shift);
  // Only succeed if no bits are lost.
  return ((word) a) == (((word) *result) >> bits_to_shift);
}

inline bool intrinsic_shr(Object* a, Object* b, Smi** result) {
  if (!are_smis(a, b)) return false;
  word bits_to_shift = Smi::cast(b)->value();
  if (bits_to_shift < 0 || bits_to_shift >= WORD_BIT_SIZE) return false;
  *result = Smi::from(Smi::cast(a)->value() >> bits_to_shift);
  return true;
}

inline bool intrinsic_ushr(Object* a, Object* b, Smi** result) {
  if (!are_smis(a, b)) return false;
  word bits_to_shift = Smi::cast(b)->value();
  word a_value = Smi::cast(a)->value();
  if (bits_to_shift < 0 || bits_to_shift >= WORD_BIT_SIZE || a_value < 0) return false;
  *result = Smi::from(a_value >> bits_to_shift);
  return true;
}

Interpreter::Result Interpreter::run() {
#define LABEL(opcode, length, format, print) &&interpret_##opcode,
  static void* dispatch_table[] = {
    BYTECODES(LABEL)
  };
#undef LABEL

  // Interpretation state.
  Program* program = process_->program();
#ifdef TOIT_CHECK_PROPAGATED_TYPES
  compiler::TypeDatabase* propagated_types =
      compiler::TypeDatabase::compute(program);
#endif
  preemption_method_header_bcp_ = null;
  uword index__ = 0;
  Object** sp;
  uint8* bcp;

  { Method pending = Method::invalid();
    sp = load_stack(&pending);
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    Object* frame_marker = POP();
    ASSERT(frame_marker == program->frame_marker());
    bcp = reinterpret_cast<uint8*>(POP());
    // When we are preempted at a call-site, we haven't done the
    // correct stack overflow check yet. We do the check now,
    // using the remembered 'pending' target method.
    // This is also another preemption check so we risk making no
    // progress if we keep getting preempted.
    if (pending.is_valid()) CHECK_STACK_OVERFLOW(pending);
  }

  // Dispatch to the first bytecode. Here we go!
  DISPATCH(0);

  OPCODE_BEGIN_WITH_WIDE(LOAD_LOCAL, stack_offset);
    PUSH(STACK_AT(stack_offset));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_0);
    PUSH(STACK_AT(0));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_1);
    PUSH(STACK_AT(1));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_2);
    PUSH(STACK_AT(2));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_3);
    PUSH(STACK_AT(3));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_4);
    PUSH(STACK_AT(4));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_5);
    PUSH(STACK_AT(5));
  OPCODE_END();

  OPCODE_BEGIN(POP_LOAD_LOCAL);
    B_ARG1(stack_offset);
    STACK_AT_PUT(0, STACK_AT(stack_offset + 1));
  OPCODE_END();

  OPCODE_BEGIN(STORE_LOCAL);
    B_ARG1(stack_offset);
    Object* value = STACK_AT(0);
    STACK_AT_PUT(stack_offset, value);
  OPCODE_END();

  OPCODE_BEGIN(STORE_LOCAL_POP);
    B_ARG1(stack_offset);
    Object* value = POP();
    STACK_AT_PUT(stack_offset - 1, value);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER);
    B_ARG1(stack_offset);
    Smi* block = Smi::cast(POP());
    Object** block_ptr = from_block(block);
    PUSH(block_ptr[stack_offset]);
  OPCODE_END();

  OPCODE_BEGIN(STORE_OUTER);
    B_ARG1(stack_offset);
    Object* value = POP();
    Smi* block = Smi::cast(POP());
    Object** block_ptr = from_block(block);
    block_ptr[stack_offset] = value;
    PUSH(value);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_FIELD, field_index);
    Instance* instance = Instance::cast(POP());
    PUSH(instance->at(field_index));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field = encoded >> 4;
    Instance* instance = Instance::cast(STACK_AT(local));
    PUSH(instance->at(field));
  OPCODE_END();

  OPCODE_BEGIN(POP_LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field = encoded >> 4;
    Instance* instance = Instance::cast(STACK_AT(local + 1));
    STACK_AT_PUT(0, instance->at(field));
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_FIELD, field_index);
    Object* value = POP();
    Instance* instance = Instance::cast(POP());
    instance->at_put(field_index, value);
    PUSH(value);
  OPCODE_END();

  OPCODE_BEGIN(STORE_FIELD_POP);
    B_ARG1(field_index)
    Object* value = POP();
    Instance* instance = Instance::cast(POP());
    instance->at_put(field_index, value);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_LITERAL, literal_index);
    PUSH(program->literals.at(literal_index));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_NULL);
    PUSH(program->null_object());
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_0);
    PUSH(Smi::from(0));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMIS_0);
    int number_of_zeros = bcp[1];
    for (int i = 0; i < number_of_zeros; i++) {
      PUSH(Smi::from(0));
    }
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_1);
    PUSH(Smi::from(1));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_U8);
    PUSH(Smi::from(bcp[1]));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_U16);
    PUSH(Smi::from(Utils::read_unaligned_uint16(bcp + 1)));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_U32);
    PUSH(Smi::from(Utils::read_unaligned_uint32(bcp + 1)));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_METHOD);
    PUSH(Smi::from(Utils::read_unaligned_uint32(bcp + 1)));
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR, global_index);
    Object** global_variables = process_->object_heap()->global_variables();
    PUSH(global_variables[global_index]);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_GLOBAL_VAR_DYNAMIC);
    int global_index = Smi::cast(POP())->value();
    if (!(0 <= global_index && global_index < program->global_variables.length())) {
      PUSH(Smi::from(program->absolute_bci_from_bcp(bcp)));
      Method target = program->program_failure();
      CALL_METHOD(target, LOAD_GLOBAL_VAR_DYNAMIC_LENGTH);
    }
    Object** global_variables = process_->object_heap()->global_variables();
    PUSH(global_variables[global_index]);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR_LAZY, global_index);
    Object** global_variables = process_->object_heap()->global_variables();
    Object* value = global_variables[global_index];
    if (is_instance(value)) {
      Instance* instance = Instance::cast(value);
      if (instance->class_id() == program->lazy_initializer_class_id()) {
        PUSH(Smi::from(global_index));
        PUSH(instance);
        Method target = program->run_global_initializer();
        CALL_METHOD(target, _length_);
      } else {
        PUSH(value);
      }
    } else {
      PUSH(value);
    }
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_GLOBAL_VAR, global_index);
    Object** global_variables = process_->object_heap()->global_variables();
    global_variables[global_index] = STACK_AT(0);
  OPCODE_END();

  OPCODE_BEGIN(STORE_GLOBAL_VAR_DYNAMIC);
    Object* value = POP();
    int global_index = Smi::cast(POP())->value();
    if (!(0 <= global_index && global_index < program->global_variables.length())) {
      PUSH(Smi::from(program->absolute_bci_from_bcp(bcp)));
      Method target = program->program_failure();
      CALL_METHOD(target, STORE_GLOBAL_VAR_DYNAMIC_LENGTH);
    }
    Object** global_variables = process_->object_heap()->global_variables();
    global_variables[global_index] = value;
  OPCODE_END();

  OPCODE_BEGIN(LOAD_BLOCK);
    B_ARG1(index);
    PUSH(to_block(sp + index));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER_BLOCK);
    B_ARG1(index);
    Smi* block = Smi::cast(POP());
    Object** block_ptr = from_block(block);
    PUSH(to_block(&block_ptr[index]));
  OPCODE_END();

  OPCODE_BEGIN(POP);
    B_ARG1(index);
    if (Flags::preemptalot) preempt();
    ASSERT(index > 0);
    DROP(index);
  OPCODE_END();

  OPCODE_BEGIN(POP_1);
    if (Flags::preemptalot) preempt();
    DROP1();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(ALLOCATE, class_index);
    Object* result = process_->object_heap()->allocate_instance(Smi::from(class_index));
    for (int attempts = 1; result == null && attempts < 4; attempts++) {
#ifdef TOIT_GC_LOGGING
      if (attempts == 3) {
        printf("[gc @ %p%s | 3rd time allocate failure %zd]\n",
            process_, VM::current()->scheduler()->is_boot_process(process_) ? "*" : " ",
            class_index);
      }
#endif //TOIT_GC_LOGGING
      sp = gc(sp, false, attempts, false);
      result = process_->object_heap()->allocate_instance(Smi::from(class_index));
    }
    if (result == null) {
      sp = push_error(sp, program->allocation_failed(), "");
      goto THROW_IMPLEMENTATION;
    }
    Instance* instance = Instance::cast(result);
    int fields = Instance::fields_from_size(program->instance_size_for(instance));
    for (int i = 0; i < fields; i++) {
      instance->at_put(i, program->null_object());
    }
    PUSH(result);
    if (Flags::gcalot) sp = gc(sp, false, 1, false);
    process_->object_heap()->check_install_heap_limit();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_CLASS, encoded);
    int class_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    Object* value = STACK_AT(0);
    bool succeeded = typecheck_class(program, value, class_index, is_nullable);
    STACK_AT_PUT(0, succeeded ? program->true_object() : program->false_object());
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_INTERFACE, encoded);
    int interface_selector_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    Object* value = STACK_AT(0);
    bool succeeded = typecheck_interface(program, value, interface_selector_index, is_nullable);
    STACK_AT_PUT(0, succeeded ? program->true_object() : program->false_object());
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_CLASS, encoded);
    int class_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    Object* value = STACK_AT(0);
    bool succeeded = typecheck_class(program, value, class_index, is_nullable);
    if (succeeded) {
      // Do nothing. Keep the object.
    } else {
      // The receiver is still on the stack.
      // Push the absolute bci of the as-check, so that we can find the class name.
      PUSH(Smi::from(program->absolute_bci_from_bcp(bcp + _length_)));
      Method target = program->as_check_failure();
      CALL_METHOD(target, _length_);
    }
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_INTERFACE, encoded);
    int interface_selector_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    Object* value = STACK_AT(0);
    bool succeeded = typecheck_interface(program, value, interface_selector_index, is_nullable);
    if (succeeded) {
      // Do nothing. Keep the object.
    } else {
      // The receiver is still on the stack.
      // Push the absolute bci of the as-check, so that we can find the interface name.
      PUSH(Smi::from(program->absolute_bci_from_bcp(bcp + _length_)));
      Method target = program->as_check_failure();
      CALL_METHOD(target, _length_);
    }
  OPCODE_END();

  OPCODE_BEGIN(AS_LOCAL);
    B_ARG1(encoded);
    int local = encoded >> 5;
    bool is_nullable = false;
    int class_interface_index = encoded & 0x1F;
    Object* value = STACK_AT(local);
    bool succeeded = typecheck_class(program, value, class_interface_index, is_nullable);
    if (succeeded) {
      // Do nothing.
    } else {
      PUSH(value);
      // Push the absolute bci of the as-check, so that we can find the interface name.
      PUSH(Smi::from(program->absolute_bci_from_bcp(bcp + AS_LOCAL_LENGTH)));
      Method target = program->as_check_failure();
      CALL_METHOD(target, AS_LOCAL_LENGTH);
    }
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC);
    S_ARG1(offset);
    Method target(program->bytecodes, program->dispatch_table[offset]);
    CALL_METHOD(target, INVOKE_STATIC_LENGTH);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC_TAIL);
    S_ARG1(offset);
    unsigned height = bcp[3];
    unsigned outer_arity = bcp[4];
    Method target(program->bytecodes, program->dispatch_table[offset]);
    unsigned call_arity = target.arity();
    // Find bcp.
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    ASSERT(STACK_AT(height) == program->frame_marker());
    uint8* return_address = reinterpret_cast<uint8*>(STACK_AT(height + 1));

    int parameter_start = height + FRAME_SIZE + outer_arity;
    // Move the arguments, overwriting the parameters to the function.
    STACK_MOVE(parameter_start, call_arity, call_arity);
    DROP(height + FRAME_SIZE + outer_arity - call_arity);
    CALL_METHOD_WITH_RETURN_ADDRESS(target, return_address);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_BLOCK);
    B_ARG1(index);
    Smi* block = Smi::cast(STACK_AT(index - 1));
    Object** block_ptr = from_block(block);
    Method target(program->bytecodes, Smi::cast(*block_ptr)->value());
    int extra = index - target.arity();
    if (extra < 0) {
      PUSH(program->true_object());  // It's a block.
      PUSH(Smi::from(target.arity()));
      PUSH(Smi::from(index));
      PUSH(Smi::from(program->absolute_bci_from_bcp(target.entry())));
      target = program->code_failure();
    } else {
      DROP(extra);
    }
    CALL_METHOD(target, INVOKE_BLOCK_LENGTH);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_INITIALIZER_TAIL);
    unsigned height = bcp[1];
    unsigned outer_arity = bcp[2];
    Smi* method_id = Smi::cast(POP());
    height--;
    Method target(program->bytecodes, method_id->value());
    unsigned call_arity = target.arity();
    if (call_arity != 0) {
      PUSH(Smi::from(program->absolute_bci_from_bcp(bcp)));
      target = program->program_failure();
      CALL_METHOD(target, INVOKE_INITIALIZER_TAIL_LENGTH);
    }
    // TODO(florian): share code with tail call and lambda invocation.
    // Find bcp.
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    ASSERT(STACK_AT(height) == program->frame_marker());
    uint8* return_address = reinterpret_cast<uint8*>(STACK_AT(height + 1));

    int parameter_start = height + FRAME_SIZE + outer_arity;
    // Move the arguments, overwriting the parameters to the function.
    STACK_MOVE(parameter_start, call_arity, call_arity);
    DROP(height + FRAME_SIZE + outer_arity - call_arity);
    CALL_METHOD_WITH_RETURN_ADDRESS(target, return_address);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(INVOKE_VIRTUAL, stack_offset);
    Object* receiver = STACK_AT(stack_offset);
    int selector_offset = Utils::read_unaligned_uint16(bcp + 2);
    Method target = program->find_method(receiver, selector_offset);
    if (!target.is_valid()) {
      PUSH(receiver);
      PUSH(Smi::from(selector_offset));
      target = program->lookup_failure();
    }
    CALL_METHOD(target, _length_);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_GET);
    Object* receiver = STACK_AT(0);
    unsigned offset = Utils::read_unaligned_uint16(bcp + 1);
    Method target = program->find_method(receiver, offset);
    if (!target.is_valid()) {
      PUSH(receiver);
      PUSH(Smi::from(offset));
      target = program->lookup_failure();
    } else if (target.is_field_accessor()) {
      int field;
      if (target.entry()[0] == LOAD_FIELD_LOCAL) {
        int argument = target.entry()[1];
        // Assert that the argument is the receiver.
        // Since we use the INVOKE_VIRTUAL_GET bytecode only when we call a method without
        //   arguments, this is the only option for a `LOAD_FIELD_LOCAL`.
        ASSERT((argument & 0x0f) == Interpreter::FRAME_SIZE);
        ASSERT(target.entry()[2] == RETURN);
        field = argument >> 4;
      } else {
        // The load_local offset is depending on the frame size.
        static_assert(FRAME_SIZE == 2, "Unexpected frame size");
        ASSERT(target.entry()[0] == LOAD_LOCAL_2);
        ASSERT(target.entry()[1] == LOAD_FIELD);
        field = target.entry()[2];
        ASSERT(target.entry()[3] == RETURN);
      }
      STACK_AT_PUT(0, Instance::cast(receiver)->at(field));
      DISPATCH(INVOKE_VIRTUAL_GET_LENGTH);
    }
    CALL_METHOD(target, INVOKE_VIRTUAL_GET_LENGTH);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_SET);
    Object* receiver = STACK_AT(1);
    unsigned offset = Utils::read_unaligned_uint16(bcp + 1);
    Method target = program->find_method(receiver, offset);
    if (!target.is_valid()) {
      PUSH(receiver);
      PUSH(Smi::from(offset));
      target = program->lookup_failure();
    } else if (target.is_field_accessor()) {
      // The load_local offsets are depending on the frame size.
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      ASSERT(target.entry()[0] == LOAD_LOCAL_3);
      ASSERT(target.entry()[1] == LOAD_LOCAL_3);
      ASSERT(target.entry()[2] == STORE_FIELD);
      int field_index = target.entry()[3];
      ASSERT(target.entry()[4] == RETURN);
      Object* value = STACK_AT(0);
      Instance::cast(receiver)->at_put(field_index, value);
      STACK_AT_PUT(1, value);
      DROP1();
      DISPATCH(INVOKE_VIRTUAL_SET_LENGTH);
    }
    CALL_METHOD(target, INVOKE_VIRTUAL_SET_LENGTH);
  OPCODE_END();

  INVOKE_VIRTUAL_FALLBACK: {
    Object* receiver = POP();
    Method target = program->find_method(receiver, index__);
    if (!target.is_valid()) {
      PUSH(receiver);
      PUSH(Smi::from(index__));
      target = program->lookup_failure();
    }
    CALL_METHOD(target, INVOKE_EQ_LENGTH);
  }

  OPCODE_BEGIN(IDENTICAL);
    Object* a0 = STACK_AT(1);
    Object* a1 = STACK_AT(0);
    if (a0 == a1) {
      STACK_AT_PUT(1, program->true_object());
    } else if (is_double(a0) && is_double(a1)) {
      auto d0 = Double::cast(a0);
      auto d1 = Double::cast(a1);
      STACK_AT_PUT(1, program->boolean(d0->bits() == d1->bits()));
    } else if (is_large_integer(a0) && is_large_integer(a1)) {
      auto l0 = LargeInteger::cast(a0);
      auto l1 = LargeInteger::cast(a1);
      STACK_AT_PUT(1, program->boolean(l0->value() == l1->value()));
    } else if (is_string(a0) && is_string(a1)) {
      auto s0 = String::cast(a0);
      auto s1 = String::cast(a1);
      STACK_AT_PUT(1, program->boolean(s0->compare(s1) == 0));
    } else {
      STACK_AT_PUT(1, program->false_object());
    }
    DROP1();
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_EQ);
    Object* a0 = STACK_AT(1);
    Object* a1 = STACK_AT(0);
    if (a0 == a1) {
      // All identical objects, except for NaNs, are equal to themselves.
      STACK_AT_PUT(1, program->boolean(!(is_double(a0) && isnan(Double::cast(a0)->value()))));
      DROP1();
      DISPATCH(INVOKE_EQ_LENGTH);
    } else if (a0 == program->null_object() || a1 == program->null_object()) {
      STACK_AT_PUT(1, program->false_object());
      DROP1();
      DISPATCH(INVOKE_EQ_LENGTH);
    } else if (are_smis(a0, a1)) {
      word i0 = Smi::cast(a0)->value();
      word i1 = Smi::cast(a1)->value();
      STACK_AT_PUT(1, program->boolean(i0 == i1));
      DROP1();
      DISPATCH(INVOKE_EQ_LENGTH);
    } else if (int result = compare_numbers(a0, a1)) {
      STACK_AT_PUT(1, program->boolean((result & COMPARE_FLAG_EQUAL) != 0));
      DROP1();
      DISPATCH(INVOKE_EQ_LENGTH);
    }
    PUSH(a0);
    index__ = program->invoke_bytecode_offset(INVOKE_EQ);
    goto INVOKE_VIRTUAL_FALLBACK;
  OPCODE_END();

#define INVOKE_RELATIONAL(opcode, op, bit)                             \
  OPCODE_BEGIN(opcode);                                                \
    Object* a0 = STACK_AT(1);                                          \
    Object* a1 = STACK_AT(0);                                          \
    if (are_smis(a0, a1)) {                                            \
      word i0 = Smi::cast(a0)->value();                                \
      word i1 = Smi::cast(a1)->value();                                \
      STACK_AT_PUT(1, program->boolean(i0 op i1));                     \
      DROP1();                                                         \
      DISPATCH(opcode##_LENGTH);                                       \
    } else if (int result = compare_numbers(a0, a1)) {                 \
      STACK_AT_PUT(1, program->boolean((result & bit) != 0));          \
      DROP1();                                                         \
      DISPATCH(opcode##_LENGTH);                                       \
    }                                                                  \
    PUSH(a0);                                                          \
    index__ = program->invoke_bytecode_offset(opcode);                 \
    goto INVOKE_VIRTUAL_FALLBACK;                                      \
  OPCODE_END();

  INVOKE_RELATIONAL(INVOKE_LT,  <  , COMPARE_FLAG_STRICTLY_LESS)
  INVOKE_RELATIONAL(INVOKE_LTE, <= , COMPARE_FLAG_LESS_EQUAL)
  INVOKE_RELATIONAL(INVOKE_GT,  >  , COMPARE_FLAG_STRICTLY_GREATER)
  INVOKE_RELATIONAL(INVOKE_GTE, >= , COMPARE_FLAG_GREATER_EQUAL)
#undef INVOKE_RELATIONAL

#define INVOKE_ARITHMETIC(opcode, op)                                  \
  OPCODE_BEGIN(opcode);                                                \
    Object* a0 = STACK_AT(1);                                          \
    Object* a1 = STACK_AT(0);                                          \
    if (are_smis(a0, a1)) {                                            \
      word i0 = Smi::cast(a0)->value();                                \
      word i1 = Smi::cast(a1)->value();                                \
      STACK_AT_PUT(1, Smi::from(op(i0, i1)));                          \
      DROP1();                                                          \
      DISPATCH(opcode##_LENGTH);                                       \
    }                                                                  \
    PUSH(a0);                                                          \
    index__ = program->invoke_bytecode_offset(opcode);                 \
    goto INVOKE_VIRTUAL_FALLBACK;                                      \
  OPCODE_END();

  INVOKE_ARITHMETIC(INVOKE_BIT_OR,  bit_or)
  INVOKE_ARITHMETIC(INVOKE_BIT_XOR, bit_xor)
  INVOKE_ARITHMETIC(INVOKE_BIT_AND, bit_and)
#undef INVOKE_ARITHMETIC

#define INVOKE_ARITHMETIC_NO_ZERO(opcode, op)                          \
  OPCODE_BEGIN(opcode);                                                \
    Object* a0 = STACK_AT(1);                                          \
    Object* a1 = STACK_AT(0);                                          \
    if (are_smis(a0, a1) && (a1 != Smi::zero())) {                     \
      word i0 = Smi::cast(a0)->value();                                \
      word i1 = Smi::cast(a1)->value();                                \
      STACK_AT_PUT(1, Smi::from(i0 op i1));                            \
      DROP1();                                                          \
      DISPATCH(opcode##_LENGTH);                                       \
    }                                                                  \
    PUSH(a0);                                                          \
    index__ = program->invoke_bytecode_offset(opcode);                 \
    goto INVOKE_VIRTUAL_FALLBACK;                                      \
  OPCODE_END();

  INVOKE_ARITHMETIC_NO_ZERO(INVOKE_DIV, /);
  INVOKE_ARITHMETIC_NO_ZERO(INVOKE_MOD, %)
#undef INVOKE_ARITHMETIC_NO_ZERO

#define INVOKE_OVERFLOW_ARITHMETIC(opcode, op)                         \
  OPCODE_BEGIN(opcode);                                                \
    Object* a0 = STACK_AT(1);                                          \
    Object* a1 = STACK_AT(0);                                          \
    Smi* result;                                                       \
    if (op(a0, a1, &result)) {                                         \
      STACK_AT_PUT(1, result);                                         \
      DROP1();                                                          \
      DISPATCH(opcode##_LENGTH);                                       \
    }                                                                  \
    PUSH(a0);                                                          \
    index__ = program->invoke_bytecode_offset(opcode);                 \
    goto INVOKE_VIRTUAL_FALLBACK;                                      \
  OPCODE_END();

  INVOKE_OVERFLOW_ARITHMETIC(INVOKE_ADD, intrinsic_add)
  INVOKE_OVERFLOW_ARITHMETIC(INVOKE_SUB, intrinsic_sub)
  INVOKE_OVERFLOW_ARITHMETIC(INVOKE_MUL, intrinsic_mul)
  INVOKE_OVERFLOW_ARITHMETIC(INVOKE_BIT_SHL, intrinsic_shl)
  INVOKE_OVERFLOW_ARITHMETIC(INVOKE_BIT_SHR, intrinsic_shr)
  INVOKE_OVERFLOW_ARITHMETIC(INVOKE_BIT_USHR, intrinsic_ushr)
#undef INVOKE_OVERFLOW_ARITHMETIC

  OPCODE_BEGIN(INVOKE_AT);
    Object* receiver = STACK_AT(1);
    Object* arg = STACK_AT(0);
    Object* value = null;

    if (fast_at(process_, receiver, arg, false, &value)) {
      STACK_AT_PUT(1, value);
      DROP1();
      DISPATCH(INVOKE_AT_LENGTH);
    }
    PUSH(receiver);
    index__ = program->invoke_bytecode_offset(INVOKE_AT);
    goto INVOKE_VIRTUAL_FALLBACK;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_AT_PUT);
    Object* receiver = STACK_AT(2);
    Object* arg = STACK_AT(1);
    Object* value = STACK_AT(0);

    if (fast_at(process_, receiver, arg, true, &value)) {
      STACK_AT_PUT(2, value);
      DROP1();
      DROP1();
      DISPATCH(INVOKE_AT_PUT_LENGTH);
    }
    PUSH(receiver);
    index__ = program->invoke_bytecode_offset(INVOKE_AT_PUT);
    goto INVOKE_VIRTUAL_FALLBACK;
  OPCODE_END();

  OPCODE_BEGIN(BRANCH);
    bcp += Utils::read_unaligned_uint16(bcp + 1);
    DISPATCH(0);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_TRUE);
    if (is_true_value(program, POP())) {
      bcp += Utils::read_unaligned_uint16(bcp + 1);
      DISPATCH(0);
    }
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_FALSE);
    if (!is_true_value(program, POP())) {
      bcp += Utils::read_unaligned_uint16(bcp + 1);
      DISPATCH(0);
    }
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK);
    uint8* entry = bcp - Utils::read_unaligned_uint16(bcp + 3);
    bcp -= Utils::read_unaligned_uint16(bcp + 1);
    CHECK_PREEMPT(entry);
    DISPATCH(0);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_TRUE);
    if (is_true_value(program, POP())) {
      uint8* entry = bcp - Utils::read_unaligned_uint16(bcp + 3);
      bcp -= Utils::read_unaligned_uint16(bcp + 1);
      CHECK_PREEMPT(entry);
      DISPATCH(0);
    }
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_FALSE);
    if (!is_true_value(program, POP())) {
      uint8* entry = bcp - Utils::read_unaligned_uint16(bcp + 3);
      bcp -= Utils::read_unaligned_uint16(bcp + 1);
      CHECK_PREEMPT(entry);
      DISPATCH(0);
    }
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_LAMBDA_TAIL);
    B_ARG1(bci_offset)
    Instance* receiver = Instance::cast(STACK_AT(bci_offset + FRAME_SIZE));
    Method target(program->bytecodes, Smi::cast(receiver->at(0))->value());
    int captured_size = 1;
    Object* argument = receiver->at(1);
    if (is_array(argument)) {
      captured_size = Array::cast(argument)->length();
    }
    int user_arity = target.arity() - captured_size;
    if (static_cast<int>(bci_offset) < user_arity) {
      PUSH(program->false_object());  // It's not a block.
      PUSH(Smi::from(user_arity));
      PUSH(Smi::from(bci_offset));
      PUSH(Smi::from(program->absolute_bci_from_bcp(target.entry())));
      target = program->code_failure();
      CALL_METHOD(target, INVOKE_LAMBDA_TAIL_LENGTH);
    } else {
      // We are simulating a tail call here.
      // TODO(florian, lau): share this code with the tail call bytecode.
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      Object* frame_marker = POP();
      ASSERT(frame_marker == program->frame_marker());
      Object* old_bcp = POP();
      // Shuffle the arguments down, so we get rid of the original receiver on the stack.
      // Also drop the arguments that are too many.
      int extra = bci_offset - user_arity;
      for (int i = bci_offset; i > extra; i--) {
        STACK_AT_PUT(i, STACK_AT(i - 1));
      }
      DROP(extra + 1);
      if (is_array(argument)) {
        Array* arguments = Array::cast(argument);
        for (int i = 0; i < captured_size; i++) {
          PUSH(arguments->at(i));
        }
      } else {
        PUSH(argument);
      }
      CALL_METHOD_WITH_RETURN_ADDRESS(target, old_bcp);
    }
  OPCODE_END();

  OPCODE_BEGIN(PRIMITIVE);
    B_ARG1(primitive_module);
    const int parameter_offset = Interpreter::FRAME_SIZE;
    unsigned primitive_index = Utils::read_unaligned_uint16(bcp + 2);
    const PrimitiveEntry* primitive = Primitive::at(primitive_module, primitive_index);
    if (Flags::primitives) printf("[invoking primitive %d::%d]\n", primitive_module, primitive_index);
    if (primitive == null) {
      PUSH(Smi::from(primitive_module));
      PUSH(Smi::from(primitive_index));
      Method target = program->primitive_lookup_failure();
      CALL_METHOD(target, PRIMITIVE_LENGTH);
    } else {
      int arity = primitive->arity;
      Primitive::Entry* entry = reinterpret_cast<Primitive::Entry*>(primitive->function);

      sp_ = sp;
      Object* result = entry(process_, sp + parameter_offset + arity - 1); // Skip the frame.
      sp = sp_;

      for (int attempts = 1; true; attempts++) {
        if (!Primitive::is_error(result)) goto done;
        result = Primitive::unmark_from_error(result);
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
          sp = push_error(sp, result, "");
          goto THROW_IMPLEMENTATION;
        }

#ifdef TOIT_GC_LOGGING
        if (attempts == 3) {
          printf("[gc @ %p%s | 3rd time primitive failure %d::%d%s]\n",
              process_, VM::current()->scheduler()->is_boot_process(process_) ? "*" : " ",
              primitive_module, primitive_index,
              malloc_failed ? " (malloc)" : "");
        }
#endif

        sp = gc(sp, malloc_failed, attempts, force_cross_process);
        sp_ = sp;
        result = entry(process_, sp + parameter_offset + arity - 1); // Skip the frame.
        sp = sp_;
      }

      // GC might have taken place in object heap but local "method" is from program heap.
      PUSH(result);
      DISPATCH(PRIMITIVE_LENGTH);

    done:
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      Object* frame_marker = POP();
      ASSERT(frame_marker == program->frame_marker());
      bcp = reinterpret_cast<uint8*>(POP());
      // Discard arguments in callers frame.
      DROP(arity);
      ASSERT(!is_stack_empty());
      PUSH(result);
      process_->object_heap()->check_install_heap_limit();
      DISPATCH(0);
    }
  OPCODE_END();

  THROW_IMPLEMENTATION:
  OPCODE_BEGIN(THROW);
    // Setup for unwinding.
    // The exception is already in TOS.
    // Push the target address (the base), and the marker that this is an exception.
    // The unwind-code will find the first finally and execute it.
    PUSH(to_block(base_));
    PUSH(Smi::from(UNWIND_REASON_WHEN_THROWING_EXCEPTION));
    goto UNWIND_IMPLEMENTATION;
  OPCODE_END();

  OPCODE_BEGIN(RETURN);
    B_ARG1(stack_offset);
    unsigned arity = bcp[2];
    Object* result = STACK_AT(0);
    // Discard expression stack elements.
    DROP(stack_offset);
    // Restore bcp.
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    Object* frame_marker = POP();
    ASSERT(frame_marker == program->frame_marker());
    bcp = reinterpret_cast<uint8*>(POP());
    // Discard arguments in callers frame.
    DROP(arity);
    ASSERT(!is_stack_empty());
    PUSH(result);
    DISPATCH(0);
  OPCODE_END();

  OPCODE_BEGIN(RETURN_NULL);
    B_ARG1(stack_offset);
    unsigned arity = bcp[2];
    // Discard expression stack elements.
    DROP(stack_offset);
    // Restore bcp.
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    Object* frame_marker = POP();
    ASSERT(frame_marker == program->frame_marker());
    bcp = reinterpret_cast<uint8*>(POP());
    // Discard arguments in callers frame.
    DROP(arity);
    ASSERT(!is_stack_empty());
    PUSH(program->null_object());
    DISPATCH(0);
  OPCODE_END();

#define NON_LOCAL_RETURN_impl(arity, height)                                                  \
    Smi* block = Smi::cast(POP());                                                            \
    Object* result = POP();                                                                   \
    Object** target_sp = from_block(block) + height + 1;                                      \
    PUSH(result);                                                                             \
    PUSH(to_block(target_sp));                                                                \
    /* -1 and -2 are used as markers.*/                                                       \
    static_assert(UNWIND_REASON_WHEN_THROWING_EXCEPTION == -2, "Unexpected unwind reason");   \
    ASSERT(Smi::from(arity << 1)->value() != -1);                                             \
    ASSERT(Smi::from(arity << 1)->value() != -2);                                             \
    PUSH(Smi::from(arity << 1));                                                              \
    goto UNWIND_IMPLEMENTATION                                                                \

  OPCODE_BEGIN(NON_LOCAL_RETURN);
    B_ARG1(encoded);
    int arity = encoded & 0x0f;
    int height = encoded >> 4;
    NON_LOCAL_RETURN_impl(arity, height);
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN_WIDE);
    int arity = Utils::read_unaligned_uint16(bcp + 1);
    uint16 height = Utils::read_unaligned_uint16(bcp + 3);
    NON_LOCAL_RETURN_impl(arity, height);
  OPCODE_END();
#undef NON_LOCAL_RETURN_impl

  OPCODE_BEGIN(NON_LOCAL_BRANCH);
    B_ARG1(height_diff);
    uint32 absolute_bci = Utils::read_unaligned_uint32(bcp + 2);
    Smi* block = Smi::cast(POP());
    Object** target_sp = from_block(block);
    index__ = 0;
    PUSH(Smi::from(height_diff));
    PUSH(to_block(target_sp));
    auto encoded_bci = Smi::from((absolute_bci << 1) | 1);
    // -1 and -2 are used as markers.
    static_assert(UNWIND_REASON_WHEN_THROWING_EXCEPTION == -2, "Unexpected unwind reason");
    ASSERT(encoded_bci->value() != -1);
    ASSERT(encoded_bci->value() != -2);
    PUSH(encoded_bci);
    goto UNWIND_IMPLEMENTATION;
  OPCODE_END();

  OPCODE_BEGIN(LINK);
    static_assert(LINK_REASON_SLOT == 1, "Unexpected reason slot");
    static_assert(LINK_TARGET_SLOT == 2, "Unexpected target slot");
    static_assert(LINK_RESULT_SLOT == 3, "Unexpected result slot");
    PUSH(Smi::from(0xbeef));           // The result of a return (of a normal return),
                                       //   the exception (of a throw), or
                                       //   the method_index and height-difference (of a non-local branch)
    PUSH(Smi::from(-0xdead));          // The target SP of an unwind.
    PUSH(Smi::from(-1));               // Marker how the unwind is entered. Can also contain arity and/or bci.
    PUSH(Smi::from(base_ - try_sp_));  // Chain to the next try_sp_ (see UNLINK below)
    try_sp_ = sp;
  OPCODE_END();

  OPCODE_BEGIN(UNLINK);
    try_sp_ = base_ - Smi::cast(POP())->value();
  OPCODE_END();

  UNWIND_IMPLEMENTATION: {
    // The tos indicates how we reached this unwind.
    // If it is '-1', then the finally is part of the normal execution and no
    //   exception, non-local return or non-local branch was encountered. The
    //   top 3 slots are not important and are only used in assert-mode for
    //   verification.
    //
    // If it is '-2', then we have encountered an exception. The target-sp is
    //   in the second slot (and the exception in the third).
    //   This case can be handled similarly to the non-local return case (below).
    //
    // If it is an integer with the last bit set to 0, then it's a non-local
    //   return. The remainder of the top-slot is the arity (which is needed
    //   for the return to pop the arguments when returning). The target-sp is
    //   in the second slot (and the value of the return in the third).
    // Both, the exception and non-local return can be handled similarly.
    //
    // If it is an integer with the last bit set, then it's a non-local branch.
    //   The remainder of the top slot contains the absolute_bci. The second slot the
    //   target-sp, and the third slot the height-difference.
    //   (Which basically adjusts the SP to the height of the loop-entry/exit).
    Object* tos = POP();
    int tos_value = Smi::cast(tos)->value();
    if (tos_value == -1) {
      // Leaving the try/finally normally. Just clean up.
      Smi* target = Smi::cast(POP());
      Object* result = POP();
      ASSERT(target == Smi::from(-0xdead));
      ASSERT(result == Smi::from(0xbeef));
      DISPATCH(UNWIND_LENGTH);
    }
    // Find target sp.
    Smi* block = Smi::cast(POP());
    Object** target_sp = from_block(block);
    Object* result_or_height_diff = POP();

    if (target_sp > try_sp_) {
      // Hit unwind protect.

      // Remember: the try-block is implemented as a 0-argument block call.
      // We want to continue the finally-block as if we had returned from the
      // try-block call. At the end of the finally-block there will be an
      // unwind.
      // Before starting the finally-block we update the link-information (at try_sp_)
      // so that the `unwind` can then proceed accordingly (continuing with the
      // non-local return or exception).
      //
      // Since the implementation of the try-block-call is deterministic we can
      // find the call from the try_sp_. We had pushed 1 for the block-pointer and
      // the `CALL_METHOD` then pushed FRAME_SIZE more entries (including the return
      // address).
      //
      // The unwind now happens in 2 steps:
      // 1. Update the link-information so that the unwind call knows what to do.
      // 2. Simulate a Return op-code from the call. This means popping the BCP and
      //   method from the stack (at the position of the try-call).

      // Set the sp to the point where we had the try-call.
      int block_pointer_slot = 1;
      int frame_size = Interpreter::FRAME_SIZE;
      sp = try_sp_ - block_pointer_slot - frame_size;
      // Update the link-information.
      int link_offset = try_sp_ - sp;
      STACK_AT_PUT(link_offset + 1, tos);
      STACK_AT_PUT(link_offset + 2, to_block(target_sp));
      STACK_AT_PUT(link_offset + 3, result_or_height_diff);

      // Simulate a return (without replacing the block-pointer with a result,
      // since it's not used anyway).
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      Object* frame_marker = POP();
      ASSERT(frame_marker == program->frame_marker());
      bcp = reinterpret_cast<uint8*>(POP());
    } else if (tos_value == UNWIND_REASON_WHEN_THROWING_EXCEPTION ||
               (tos_value & 1) == 0) {
      // An exception or non-local return.
      // Unwind to specific target (not finally block).
      int arity = tos_value == UNWIND_REASON_WHEN_THROWING_EXCEPTION
          ? 0
          : tos_value >> 1;
      sp = target_sp;
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      Object* frame_marker = POP();
      if (frame_marker != program->frame_marker()) {
        // This is the most likely explanation for a missing frame marker.
        FATAL("Threw exception before entering last-chance catch clause");
      }
      bcp = reinterpret_cast<uint8*>(POP());
      // Discard arguments in callers frame.
      DROP(arity);
      ASSERT(!is_stack_empty());
      PUSH(result_or_height_diff);
    } else {
      // A non-local branch.
      int absolute_bci = tos_value >> 1;
      int height_diff = Smi::cast(result_or_height_diff)->value();
      sp = target_sp;
      bcp = program->bcp_from_absolute_bci(absolute_bci);
      DROP(height_diff);
    }
    DISPATCH(0);
  }

  OPCODE_BEGIN(UNWIND);
    goto UNWIND_IMPLEMENTATION;
  OPCODE_END();

  OPCODE_BEGIN(HALT);
    B_ARG1(return_code);
    if (return_code == 0) {
      // Push a return value for when we resume from yield.
      PUSH(Smi::from(91));
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      PUSH(reinterpret_cast<Object*>(bcp + HALT_LENGTH));
      PUSH(program->frame_marker());
      store_stack(sp);
      if (Flags::trace) printf("[yield from interpretation]\n");
      return Result(Result::YIELDED);
    } else if (return_code == 1) {
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      PUSH(reinterpret_cast<Object*>(bcp + HALT_LENGTH));
      PUSH(program->frame_marker());
      store_stack(sp);
      if (Flags::trace) printf("[stop interpretation]\n");
      return Result(0);
    } else if (return_code == 2) {
      int exit_value = Smi::cast(POP())->value();
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      PUSH(reinterpret_cast<Object*>(bcp + HALT_LENGTH));
      PUSH(program->frame_marker());
      store_stack(sp);
      if (Flags::trace) printf("[exit interpretation exit_value=%d]\n", exit_value);
      return Result(exit_value);
    } else {
      ASSERT(return_code == 3);
      Object* duration = POP();
      int64 value = 0;
      if (is_smi(duration)) {
        value = Smi::cast(duration)->value();
      } else if (is_large_integer(duration)) {
        value = LargeInteger::cast(duration)->value();
      } else {
        FATAL("Cannot handle non-numeric deep sleep argument");
      }
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      PUSH(reinterpret_cast<Object*>(bcp + HALT_LENGTH));
      PUSH(program->frame_marker());
      store_stack(sp);
      if (Flags::trace) printf("[exit interpretation]\n");
      return Result(Result::DEEP_SLEEP, value);
    }
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_SMI_REPEAT);
    DROP1();  // Drop last result of calling the block (or initial discardable value).
    Smi* current = Smi::cast(STACK_AT(0));
    // Load the parameters to Array.do.
    int parameter_offset = 1 + Interpreter::FRAME_SIZE;  // 1 for the `current`.
    Smi* block = Smi::cast(STACK_AT(parameter_offset + 0));
    Smi* end = Smi::cast(STACK_AT(parameter_offset + 1));  // This.

    Object** block_ptr = from_block(block);
    Method target = Method(program->bytecodes, Smi::cast(*block_ptr)->value());

    // If the block takes the wrong number of arguments, we let the intrinsic fail and
    // continue to the next bytecode (like for primitives).
    if (target.arity() > 2) DISPATCH(INTRINSIC_SMI_REPEAT_LENGTH);

    // Once we're past the end index, we return from the surrounding method just
    // like primitive calls do.
    word current_value = current->value();
    if (current_value >= end->value()) {
      DROP1();
      // Restore bcp.
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      Object* frame_marker = POP();
      ASSERT(frame_marker == program->frame_marker());
      bcp = reinterpret_cast<uint8*>(POP());
      // Discard arguments in callers frame.
      DROP1();
      ASSERT(!is_stack_empty());
      STACK_AT_PUT(0, program->null_object());
      DISPATCH(0);
    }

    // Invoke the given block argument and set it up so we keep executing
    // this bytecode when we return from it.
    STACK_AT_PUT(0, Smi::from(current_value + 1));
    PUSH(block);
    if (target.arity() == 2) PUSH(current);
    CALL_METHOD(target, 0);  // Continue at the same bytecode.
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_ARRAY_DO);
    DROP1();  // Drop last result of calling the block (or initial discardable value).
    word current = Smi::cast(STACK_AT(0))->value();
    // Load the parameters to Array.do.
    int parameter_offset = 1 + Interpreter::FRAME_SIZE;  // 1 for the `current`.
    Smi* block = Smi::cast(STACK_AT(parameter_offset + 0));
    Smi* end = Smi::cast(STACK_AT(parameter_offset + 1));
    Array* backing = Array::cast(STACK_AT(parameter_offset + 2));

    Object** block_ptr = from_block(block);
    Method target = Method(program->bytecodes, Smi::cast(*block_ptr)->value());

    // If the block takes the wrong number of arguments, we let the intrinsic fail and
    // continue to the next bytecode (like for primitives).
    if (target.arity() > 2) DISPATCH(INTRINSIC_ARRAY_DO_LENGTH);

    // Once we're past the end index, we return from the surrounding method just
    // like primitive calls do.
    if (current >= end->value()) {
      DROP1();
      // Restore bcp.
      static_assert(FRAME_SIZE == 2, "Unexpected frame size");
      Object* frame_marker = POP();
      ASSERT(frame_marker == program->frame_marker());
      bcp = reinterpret_cast<uint8*>(POP());
      // Discard arguments in callers frame.
      DROP(2);
      ASSERT(!is_stack_empty());
      STACK_AT_PUT(0, program->null_object());
      DISPATCH(0);
    }

    // Invoke the given block argument and set it up so we keep executing
    // this bytecode when we return from it.
    STACK_AT_PUT(0, Smi::from(current + 1));
    PUSH(block);
    if (target.arity() == 2) PUSH(backing->at(current));
    CALL_METHOD(target, 0);  // Continue at the same bytecode.
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_HASH_DO);
    // This opcode attempts to implement the hash_do_ method on hash sets and
    // maps.  This mainly consists of iterating over the backing list, skipping
    // instances of Tombstone_.  The backing is a form of skip-list where the
    // Tombstone_ instances can indicate how far to go to find the next entry.
    // We have to update these instances to keep the number of skip operations
    // down.
    // State offsets.
    enum {
      STATE = 0,  // Must be zero and the stack slot must be initialized to null.
      NUMBER_OF_BYTECODE_LOCALS,
    };
    // Parameter offsets.
    enum {
      BLOCK,
      REVERSED,
      STEP,
      COLLECTION,
      NUMBER_OF_ARGUMENTS,
    };
    // On entry to the byte code, the TOS has the result of the previous block
    // invocation or a dummy value.  We discard it.  Next is the location of
    // the previous entry that was handled, or null the first time.
    DROP1();
    // The bytecode should be run on an empty stack.
    ASSERT(STACK_AT(NUMBER_OF_BYTECODE_LOCALS) == program->frame_marker());
    int parameter_offset = NUMBER_OF_BYTECODE_LOCALS + Interpreter::FRAME_SIZE;

    Instance* collection = Instance::cast(STACK_AT(parameter_offset + COLLECTION));
    Object* backing = collection->at(Instance::MAP_BACKING_INDEX);
    int step = Smi::cast(STACK_AT(parameter_offset + STEP))->value();
    if (program->true_object() == STACK_AT(parameter_offset + REVERSED)) step = -step;
    Object* entry;
    Object* return_value = hash_do(program, STACK_AT(STATE), backing, step, STACK_AT(parameter_offset + BLOCK), &entry);
    if (is_smi(return_value) && Smi::cast(return_value)->value() < 0) {
      // Negative Smi means call the block.
      word c = -(Smi::cast(return_value)->value() + 1);
      STACK_AT_PUT(STATE, Smi::from(c));
      Smi* block = Smi::cast(STACK_AT(parameter_offset + BLOCK));
      Method target = Method(program->bytecodes, Smi::cast(*from_block(block))->value());
      PUSH(block);
      PUSH(entry);
      if (target.arity() > 2) {
        Object* value;
        bool result = fast_at(process_, backing, Smi::from(c + 1), false, &value);
        ASSERT(result);
        PUSH(value);
      }
      // Call block, afterwards continue at the same bytecode.
      CALL_METHOD(target, 0);
      UNREACHABLE();
    }
    // We return from the surrounding method just like primitive calls do.
    DROP(NUMBER_OF_BYTECODE_LOCALS);
    // Restore bcp.
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    Object* frame_marker = POP();
    ASSERT(frame_marker == program->frame_marker());
    bcp = reinterpret_cast<uint8*>(POP());
    // Discard arguments in callers frame.
    DROP(NUMBER_OF_ARGUMENTS - 1);
    ASSERT(!is_stack_empty());
    STACK_AT_PUT(0, return_value);
    DISPATCH(0);
    UNREACHABLE();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_HASH_FIND); {
    Method block_to_call(0);
    HashFindAction action;
    Object* result;
    sp = hash_find(sp, program, &action, &block_to_call, &result);
    if (action == kBail) {
      DISPATCH(INTRINSIC_HASH_FIND_LENGTH);
    } else if (action == kRestartBytecode) {
      DISPATCH(0);
    } else if (action == kReturnValue) {
      bcp = reinterpret_cast<uint8*>(POP());
      ASSERT(!is_stack_empty());
      STACK_AT_PUT(0, result);
      DISPATCH(0);
    } else {
      ASSERT(action == kCallBlockThenRestartBytecode);
      CALL_METHOD(block_to_call, 0);  // Continue at the same bytecode after the block call.
    }
  }
  OPCODE_END();
}

#undef DISPATCH
#undef DISPATCH_TO
#undef OPCODE_BEGIN
#undef OPCODE_END

Object** Interpreter::hash_find(Object** sp, Program* program, Interpreter::HashFindAction* action_return, Method* block_to_call, Object** result_to_return) {
  // This opcode attempts to implement the find_body_ method on hash sets and
  // maps.  It is best read in conjunction with that method, remembering
  // that the byte code restarts after each block call.  It take three blocks:
  // [not_found] This is called at most once if the entry is not
  //             found.  For methods like `contains` it will not return.  In
  //             other cases it will add a new entry to the backing and
  //             return the position to be entered in the index.  We remember
  //             if we have called this and never call it twice.
  // [rebuild]   This rebuilds the index, usually because it is full.  It
  //             is only called after not_found, and we restart the whole
  //             index search after this.
  // [compare]   This is called to compare two items, one in the collection and
  //             one new key.  It is only called if the low bits of the hash
  //             code match, and we handle common cases where the objects are
  //             equal and of simple types without calling it.  In the case
  //             where this returns true we don't have much work to do.  The
  //             case where it returns false is quite rare and it would be OK
  //             to fall back to Toit code in this case, but we have to
  //             preserve `append_position` which ensures we don't call the
  //             not_found block again.

  // Local variable offsets.  We push zeros onto the stack just before the HASH_FIND
  // bytecode so that it has space for these locals.
  enum {
    STATE = 0,  // Must be zero and the stack slot must be initialized to zero (STATE_START).
    OLD_SIZE,   // Other enum values auto-increment.
    DELETED_SLOT,
    SLOT,
    POSITION,
    SLOT_STEP,
    STARTING_SLOT,
    NUMBER_OF_BYTECODE_LOCALS,  // Must be last.
  };
  // Parameter offsets, correspond to the argument order of hash_find_.
  enum {
    COMPARE             = 0,
    REBUILD             = 1,
    NOT_FOUND           = 2,
    APPEND_POSITION     = 3,
    HASH                = 4,
    KEY                 = 5,
    COLLECTION          = 6,
    NUMBER_OF_ARGUMENTS = 7,  // Must be last.
  };
  // States.
  enum {
    STATE_START = 0,  // Must be zero - initial value of local variables pushed just before the byte code.
    STATE_NOT_FOUND,
    STATE_REBUILD,
    STATE_AFTER_COMPARE,
  };
  // Return value of find_, coordinate with collections.toit
  static const int APPEND_ = -1;

  static const int INVALID_SLOT = -1;

  // Coordinate constants with collections.toit.
  static const int HASH_SHIFT_ = 12;
  static const int HASH_MASK_ = ((1 << HASH_SHIFT_) - 1);

  // Either the result of the previously called block or (the first time we
  // run the bytecode) a zero.
  Object* block_result = POP();

  // This bytecode should be run with an empty stack.
  ASSERT(STACK_AT(NUMBER_OF_BYTECODE_LOCALS) == program->frame_marker());
  int parameter_offset = NUMBER_OF_BYTECODE_LOCALS + Interpreter::FRAME_SIZE;

  int state = Smi::cast(STACK_AT(STATE))->value();
  if (state == STATE_REBUILD) {
    // Store result of calling not_found block.
    STACK_AT_PUT(parameter_offset + APPEND_POSITION, block_result);
    // Ensure we will restart the index search after rebuild.
    STACK_AT_PUT(STATE, Smi::from(STATE_START));
    // Call the rebuild block with old_size as argument.
    Smi* rebuild_block = Smi::cast(STACK_AT(parameter_offset + REBUILD));
    Method rebuild_target = Method(program->bytecodes, Smi::cast(*from_block(rebuild_block))->value());
    PUSH(rebuild_block);
    PUSH(STACK_AT(OLD_SIZE));
    *block_to_call = rebuild_target;
    *action_return = kCallBlockThenRestartBytecode;
    return sp;
  }

  Object* hash_object = STACK_AT(parameter_offset + HASH);
  Instance* collection = Instance::cast(STACK_AT(parameter_offset + COLLECTION));
  // Some safety checking.  We only need this on the first entry (state 0) but we do
  // it again after state 3, where we called the user-provided compare routine, which
  // could mess with our assumptions.
  // We only support small arrays as index_.
  if (state == STATE_START || state == STATE_AFTER_COMPARE) {
    Object* index_spaces_left_object = collection->at(Instance::MAP_SPACES_LEFT_INDEX);
    Object* size_object = collection->at(Instance::MAP_SIZE_INDEX);
    Object* not_found_block = *from_block(Smi::cast(STACK_AT(parameter_offset + NOT_FOUND)));
    Object* rebuild_block   = *from_block(Smi::cast(STACK_AT(parameter_offset + REBUILD)));
    Object* compare_block   = *from_block(Smi::cast(STACK_AT(parameter_offset + COMPARE)));
    Method not_found_target = Method(program->bytecodes, Smi::cast(not_found_block)->value());
    Method rebuild_target   = Method(program->bytecodes, Smi::cast(rebuild_block)->value());
    Method compare_target   = Method(program->bytecodes, Smi::cast(compare_block)->value());
    if (!is_smi(index_spaces_left_object)
     || !is_smi(hash_object)
     || !is_smi(size_object)
     || not_found_target.arity() != 1
     || rebuild_target.arity() != 2
     || compare_target.arity() != 3) {
      // Let the intrinsic fail and continue to the next bytecode (like for
      // primitives).
      // Leave one value on the stack, which the compiler expects to find as
      // the result of the intrinsic.
      DROP(NUMBER_OF_BYTECODE_LOCALS - 1);
      *action_return = kBail;
      return sp;
    }
  }
  Object* index_object = collection->at(Instance::MAP_INDEX_INDEX);
  word index_mask;
  if (is_array(index_object)) {
    index_mask = Array::cast(index_object)->length() - 1;
    ASSERT(Array::ARRAYLET_SIZE < (Smi::MAX_SMI_VALUE >> HASH_SHIFT_));
  } else {
    bool bail = true;
    if (is_instance(index_object) && HeapObject::cast(index_object)->class_id() == program->large_array_class_id()) {
      Object* size_object = Instance::cast(index_object)->at(Instance::LARGE_ARRAY_SIZE_INDEX);
      if (is_smi(size_object)) {
        index_mask = Smi::cast(size_object)->value() - 1;
        bail = false;
      }
    }
    if (bail || index_mask >= (Smi::MAX_SMI_VALUE >> HASH_SHIFT_)) {
      // We don't want to run into number allocation problems when we construct
      // the hash-and-position.  This is basically only an issue on the server
      // in the 32 bit VM - others don't have enough memory to hit it.  Bail out.
      // Leave one value on the stack, which the compiler expects to find as
      // the result of the intrinsic.
      DROP(NUMBER_OF_BYTECODE_LOCALS - 1);
      *action_return = kBail;
      return sp;
    }
  }
  ASSERT(Utils::is_power_of_two(index_mask + 1));

  word hash = Smi::cast(hash_object)->value();

  if (state == STATE_NOT_FOUND) {
    Object* append_position = block_result;
    STACK_AT_PUT(parameter_offset + APPEND_POSITION, append_position);
    ASSERT(is_smi(append_position));
    // Update free position in index with new entry.
    word new_hash_and_position = ((Smi::cast(append_position)->value() + 1) << HASH_SHIFT_) | (hash & HASH_MASK_);
    ASSERT(Smi::is_valid(new_hash_and_position));
    word deleted_slot = Smi::cast(STACK_AT(DELETED_SLOT))->value();
    word index_position;
    if (deleted_slot < 0) {
      // Calculate index for: index_[slot] = new_hash_and_position
      index_position = Smi::cast(STACK_AT(SLOT))->value() & index_mask;
      // index_spaces_left_--
      Object* index_spaces_left_object = collection->at(Instance::MAP_SPACES_LEFT_INDEX);
      word index_spaces_left = Smi::cast(index_spaces_left_object)->value();
      collection->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(index_spaces_left - 1));
    } else {
      // Calculate index for: index_[deleted_slot] = new_hash_and_position
      index_position = deleted_slot & index_mask;
    }
    Object* entry = Smi::from(new_hash_and_position);
    if (is_array(index_object)) {
      Array::cast(index_object)->at_put(index_position, entry);
    } else {
      bool success = fast_at(process_, index_object, Smi::from(index_position), true, &entry);
      ASSERT(success);
    }
  }

  if (state == STATE_NOT_FOUND ||
      (state == STATE_AFTER_COMPARE && is_true_value(program, block_result))) {
    // We now have an entry in the index for the new entry (we either found one or
    // created one in the STATE_NOT_FOUND code above), so we return the
    // position in the backing to our caller.
    Object* result;
    if (state == STATE_NOT_FOUND) {
      result = Smi::from(APPEND_);
    } else {
      Object* append_position = STACK_AT(parameter_offset + APPEND_POSITION);
      if (is_smi(append_position)) {
        result = Smi::from(APPEND_);
      } else {
        result = STACK_AT(POSITION);
      }
    }
    // Return result.
    DROP(NUMBER_OF_BYTECODE_LOCALS);
    // Restore bcp.
    static_assert(FRAME_SIZE == 2, "Unexpected frame size");
    Object* frame_marker = POP();
    ASSERT(frame_marker == program->frame_marker());
    *result_to_return = result;
    Object* new_bcp = POP();
    // Discard arguments in callers frame.
    DROP(NUMBER_OF_ARGUMENTS - 1);
    PUSH(new_bcp);
    *action_return = kReturnValue;
    return sp;
  }

  // These three must be synced to their local variable stack slots before
  // restarting the byte code.  They are used for normal flow control in the
  // while loop below.
  word slot;
  word slot_step;
  word starting_slot;

  bool increment;
  if (state == STATE_START) {
    // Initial values for the search in the hash index.
    slot = hash & index_mask;
    starting_slot = slot;
    STACK_AT_PUT(DELETED_SLOT, Smi::from(INVALID_SLOT));
    slot_step = 1;
    increment = false;
  } else {
    ASSERT(state == STATE_AFTER_COMPARE);  // State AFTER_COMPARE with false compare result.
    ASSERT(!is_true_value(program, block_result));
    // We reinitialize these locals from the Toit stack.
    slot          = Smi::cast(STACK_AT(SLOT))->value() & index_mask;
    starting_slot = Smi::cast(STACK_AT(STARTING_SLOT))->value();
    slot_step     = Smi::cast(STACK_AT(SLOT_STEP))->value();
    increment = true;
  }
  // Look or keep looking through the index.
  while (true) {
    bool exhausted = false;
    if (increment) {
      slot += slot_step;
      slot &= index_mask;
      slot_step++;
      exhausted = (slot == starting_slot);
    }
    increment = true;
    word hash_and_position;
    if (is_array(index_object)) {
      hash_and_position = Smi::cast(Array::cast(index_object)->at(slot))->value();
    } else {
      Object* hap;
      bool success = fast_at(process_, index_object, Smi::from(slot), false, &hap);
      ASSERT(success);
      ASSERT(is_smi(hap));
      hash_and_position = Smi::cast(hap)->value();
    }
    if (hash_and_position == 0 || exhausted) {
      // Found free slot.
      Object* index_spaces_left_object = collection->at(Instance::MAP_SPACES_LEFT_INDEX);
      word index_spaces_left = Smi::cast(index_spaces_left_object)->value();
      if (index_spaces_left == 0 || exhausted) {
        Object* size_object = collection->at(Instance::MAP_SIZE_INDEX);
        STACK_AT_PUT(OLD_SIZE, size_object);
        STACK_AT_PUT(STATE, Smi::from(STATE_REBUILD)); // Go there if not_found returns.
      } else {
        STACK_AT_PUT(SLOT, Smi::from(slot));
        STACK_AT_PUT(STATE, Smi::from(STATE_NOT_FOUND)); // Go there if not_found returns.
      }
      Object* append_position = STACK_AT(parameter_offset + APPEND_POSITION);
      if (!is_smi(append_position)) {  // If it is null we haven't called not_found yet.
        Smi* not_found_block = Smi::cast(STACK_AT(parameter_offset + NOT_FOUND));
        Method not_found_target =
            Method(program->bytecodes, Smi::cast(*from_block(not_found_block))->value());
        PUSH(not_found_block);
        *block_to_call = not_found_target;
        *action_return = kCallBlockThenRestartBytecode;
        return sp;
      } else {
        // Here we already called the not_found block once, so we want to go
        // directly to state NOT_FOUND or REBUILD without a block call.  This
        // is quite rare, so we do the simple solution.  We push the append
        // position as if it had been returned from the block, then restart
        // the byte code to go to the correct place.
        PUSH(append_position);  // Fake block return value.
        *action_return = kRestartBytecode;
        return sp;
      }
    }
    // Found non-free slot.
    Smi* position = Smi::from((hash_and_position >> HASH_SHIFT_) - 1);
    // k := backing_[position]
    Object* backing_object = HeapObject::cast(collection->at(Instance::MAP_BACKING_INDEX));
    Object* k;
    bool success = fast_at(process_, backing_object, position, false, &k);
    ASSERT(success);
    word deleted_slot = Smi::cast(STACK_AT(DELETED_SLOT))->value();
    // if deleted_slot is invalid and k is Tombstone_
    if (deleted_slot == INVALID_SLOT && !is_smi(k) && HeapObject::cast(k)->class_id() == program->tombstone_class_id()) {
      STACK_AT_PUT(DELETED_SLOT, Smi::from(slot));
    }
    if ((hash_and_position & HASH_MASK_) == (hash & HASH_MASK_)) {
      if (is_smi(k) || HeapObject::cast(k)->class_id() != program->tombstone_class_id()) {
        // Found hash match.
        // TODO: Handle string and number cases here.
        STACK_AT_PUT(STATE, Smi::from(STATE_AFTER_COMPARE)); // Go there afterwards.
        STACK_AT_PUT(SLOT, Smi::from(slot));
        STACK_AT_PUT(STARTING_SLOT, Smi::from(starting_slot));
        STACK_AT_PUT(SLOT_STEP, Smi::from(slot_step));
        STACK_AT_PUT(POSITION, position);
        Smi* compare_block = Smi::cast(STACK_AT(parameter_offset + COMPARE));
        Method compare_target = Method(program->bytecodes, Smi::cast(*from_block(compare_block))->value());
        Object* key = STACK_AT(parameter_offset + KEY);
        PUSH(compare_block);
        PUSH(key);
        PUSH(k);
        *block_to_call = compare_target;
        *action_return = kCallBlockThenRestartBytecode;
        return sp;
      }
    }
  }  // while(true) loop.
}

} // namespace toit

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

#include "emitter.h"
#include "bytecode_format.h"
#include "../objects_inline.h"
#include "../interpreter.h"
#include "../interpreter_v2.h"
#include "limits.h"

namespace toit {
namespace compiler {

static const int MIN_BYTECODE_VALUE = 0;
static const int MAX_BYTECODE_VALUE = UCHAR_MAX;
// TODO(Lau): Inline max value:
static const int MAX_USHORT_VALUE   = USHRT_MAX;

// Number of words between the parameters and the locals of a frame. In
// format 2 the return address and frame marker live on a separate frame
// stack, so the parameters are directly below the locals.
static int frame_size() {
  return is_format2() ? 0 : Interpreter::FRAME_SIZE;
}

inline void Emitter::emit(Opcode opcode, int value) {
  ASSERT(MIN_BYTECODE_VALUE <= value && value <= MAX_BYTECODE_VALUE);
  emit_opcode(opcode);
  emit_uint8(value);
}

inline void Emitter::emit_opcode(Opcode opcode) {
  opcode_positions_.add(position());
  builder_.add(opcode);
}

inline void Emitter::emit_uint8(uint8 value) {
  builder_.add(value & 0xff);
}

inline void Emitter::emit_uint16(uint16 value) {
  builder_.add(value & 0xff);
  builder_.add(value >> 8);
}

inline void Emitter::emit_uint16_at(int offset, uint16 value) {
  builder_[offset] = value & 0xff;
  builder_[offset + 1] = value >> 8;
}

inline void Emitter::emit_uint32(uint32 value) {
  builder_.add((value >>  0) & 0xff);
  builder_.add((value >>  8) & 0xff);
  builder_.add((value >> 16) & 0xff);
  builder_.add((value >> 24) & 0xff);
}

List<uint8> Emitter::bytecodes() {
  return builder_.build();
}

int Emitter::relocated(int position) const {
  if (relocation_.empty()) return position;
  ASSERT(0 <= position && position < static_cast<int>(relocation_.size()));
  return relocation_[position];
}

void Emitter::relax_branches() {
  ASSERT(is_format2());
  ASSERT(relocation_.empty());
  int length = builder_.length();
  // The instructions: start, length, and for the ones with a distance the
  // index of the target instruction (or -1).
  struct Instruction {
    int start;
    int length;
    int target;      // Index into `instructions` (the end is index `count`).
    bool candidate;  // A branch with a short form (BRANCH .. BRANCH_IF_NOT_NULL, BRANCH_BACK).
    bool is_short;
  };
  std::vector<Instruction> instructions;
  std::vector<int> index_at(length + 1, -1);
  for (int i = 0; i < length;) {
    int opcode = builder_[i];
    ASSERT(opcode < V2_OPCODE_COUNT);
    int len = V2_OPCODE_LENGTHS[opcode];
    ASSERT(i + len <= length);
    index_at[i] = instructions.size();
    instructions.push_back({ i, len, -1, false, false });
    i += len;
  }
  int count = instructions.size();
  index_at[length] = count;
  bool any = false;
  for (auto& instruction : instructions) {
    int i = instruction.start;
    int opcode = builder_[i];
    bool forward;
    if (BRANCH <= opcode && opcode <= BRANCH_IF_NOT_NULL) {
      forward = true;
    } else if (BRANCH_BACK <= opcode && opcode <= BRANCH_BACK_IF_NOT_NULL) {
      forward = false;
    } else if (opcode == V2_LOOP_REPEAT || opcode == V2_LOOP_ARRAY) {
      forward = false;
    } else if (opcode == V2_HASH_FIND) {
      forward = true;
    } else {
      continue;
    }
    int distance = builder_[i + 1] | (builder_[i + 2] << 8);
    int target = forward ? i + distance : i - distance;
    ASSERT(0 <= target && target <= length && index_at[target] >= 0);
    instruction.target = index_at[target];
    // A forward distance 0 (a label never bound) stays as it is: the
    // verifier rejects it.
    instruction.candidate = (BRANCH <= opcode && opcode <= BRANCH_BACK) && (distance > 0 || !forward);
    instruction.is_short = instruction.candidate;
    any = any || instruction.candidate;
  }
  if (!any) return;
  // New starts, for the current choice of short branches.
  std::vector<int> starts(count + 1);
  auto layout = [&]() {
    int position = 0;
    for (int j = 0; j < count; j++) {
      starts[j] = position;
      position += instructions[j].is_short ? 2 : instructions[j].length;
    }
    starts[count] = position;
  };
  bool changed = true;
  while (changed) {
    changed = false;
    layout();
    for (int j = 0; j < count; j++) {
      auto& instruction = instructions[j];
      if (!instruction.is_short) continue;
      int distance = starts[instruction.target] - starts[j];
      if (distance < 0) distance = -distance;
      if (distance > MAX_BYTECODE_VALUE) {
        instruction.is_short = false;
        changed = true;
      }
    }
  }
  // Every short branch fits with the final layout (the last pass changed
  // nothing). Rewrite the code.
  ListBuilder<uint8> code;
  relocation_.assign(length + 1, 0);
  for (int j = 0; j < count; j++) {
    auto& instruction = instructions[j];
    int i = instruction.start;
    int opcode = builder_[i];
    for (int k = 0; k < instruction.length; k++) {
      // A short branch's second byte is its operand; positions inside it
      // are never recorded.
      relocation_[i + k] = starts[j] + (instruction.is_short ? std::min(k, 1) : k);
    }
    if (instruction.target < 0) {
      for (int k = 0; k < instruction.length; k++) code.add(builder_[i + k]);
      continue;
    }
    int distance = starts[instruction.target] - starts[j];
    if (distance < 0) distance = -distance;
    if (instruction.is_short) {
      ASSERT(0 <= distance && distance <= MAX_BYTECODE_VALUE);
      ASSERT(opcode == BRANCH_BACK || distance > 0);
      code.add(opcode == BRANCH_BACK ? V2_BRANCH_BACK_S : V2_BRANCH_S + (opcode - BRANCH));
      code.add(distance);
    } else {
      if (distance > MAX_USHORT_VALUE) FATAL("branch distance does not fit 16 bits");
      code.add(opcode);
      code.add(distance & 0xff);
      code.add(distance >> 8);
      for (int k = 3; k < instruction.length; k++) code.add(builder_[i + k]);
    }
  }
  relocation_[length] = starts[count];
  ASSERT(code.length() == starts[count]);
  builder_ = code;
  // The positions recorded during the emission.
  for (int j = 0; j < absolute_uses_.length(); j++) {
    AbsoluteUse* use = absolute_uses_[j];
    use->relocate(relocated(use->relative_position()));
  }
  for (int j = 0; j < absolute_references_.length(); j++) {
    auto& reference = absolute_references_[j];
    reference.relocate(relocated(reference.relative_position()));
  }
  opcode_positions_.clear();
  last_bound_ = 0;
}

inline void Emitter::emit_possibly_wide(Opcode op, word value) {
  if (value <= MAX_BYTECODE_VALUE) {
    emit(op, value);
  } else {
    if (value > MAX_USHORT_VALUE) {
      FATAL("Cannot emit value larger than ushort.");
    }
    op = static_cast<Opcode>(op + 1);
    emit_opcode(op);
    emit_uint16(value);
  }
}

void Emitter::emit_load_local(int offset) {
  int value;
  if (offset <= MAX_BYTECODE_VALUE && last_is(POP_1, null)) {
    // Make sure that the last bytecode is the last byte and patch it
    // to be the combination of 'pop' and 'load local'.
    unsigned index = position() - 1;
    ASSERT(opcode_positions_.last() == index);
    builder_[index] = POP_LOAD_LOCAL;
    emit_uint8(offset);
  } else if (offset <= MAX_BYTECODE_VALUE &&
      last_is(POP, &value) &&
      value == 2) {
    // We change this to POP_1, followed by POP_LOAD_LOCAL, as this make
    //   other peepholes easier to implement.
    int previous_position = opcode_positions_.last();
    builder_[previous_position] = POP_1;
    ASSERT(builder_.last() == 2);  // The POP value.
    builder_.remove_last();
    emit(POP_LOAD_LOCAL, offset);
  } else if (offset >= 0 && offset <= 5) {
    emit_opcode(static_cast<Opcode>(LOAD_LOCAL_0 + offset));
  } else {
    emit_possibly_wide(LOAD_LOCAL, offset);
  }
}

bool Emitter::last_is(Opcode opcode, int* value) {
  if (previous_opcode() != opcode) return false;
  if (value) *value = builder_[opcode_positions_.last()  + 1];
  return true;
}

Opcode Emitter::previous_opcode(int n) {
  if (opcode_positions_.length() <= n) return ILLEGAL_END;
  auto position = opcode_positions_[opcode_positions_.length() - 1 - n];
  if (position < last_bound_) return ILLEGAL_END;
  return static_cast<Opcode>(builder_[position]);
}

void Emitter::bind(Label* label) {
  ASSERT(!label->is_bound());
  int position = this->position();
  for (int i = 0; i < label->uses(); i++) {
    int use = label->use_at(i);
    int offset = position - use;
    ASSERT(builder_[use + 1] == 0 && builder_[use + 2] == 0);
    emit_uint16_at(use + 1, offset);
  }
  label->bind(position, height());
  last_bound_ = position;
}

void Emitter::load_integer(word value) {
  // Due to cross platform compatibility, only 32-bit smis can be loaded
  // from the bytecodes. We use the literal array for the other smis. Without
  // this restriction, we would have to rewrite bytecodes to deal with the
  // differences between 32-bit and 64-bit machines.
  ASSERT(Smi::is_valid32(value));
  if (value == 0) {
    emit_opcode(LOAD_SMI_0);
  } else if (value == 1) {
    emit_opcode(LOAD_SMI_1);
  } else if (value < 256) {
    emit_opcode(LOAD_SMI_U8);
    emit_uint8(value);
  } else if (value < 65536) {
    emit_opcode(LOAD_SMI_U16);
    emit_uint16(value);
  } else {
    emit_opcode(LOAD_SMI_U32);
    emit_uint32(value);
  }
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::load_method(int offset) {
  ASSERT(offset >= 0);
  emit_opcode(LOAD_METHOD);
  emit_uint32(offset);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::load_n_smis(int n) {
  ASSERT(0 < n && n < 0x100);
  emit(LOAD_SMIS_0, n);
  for (int i = 0; i < n; i++) {
    stack_.push(ExpressionStack::OBJECT);
  }
}

void Emitter::load_literal(int index) {
  ASSERT(index >= 0);
  emit_possibly_wide(LOAD_LITERAL, index);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::load_null() {
  emit_opcode(LOAD_NULL);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::load_global_var(int global_id, bool is_lazy) {
  emit_possibly_wide(is_lazy ? LOAD_GLOBAL_VAR_LAZY : LOAD_GLOBAL_VAR, global_id);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::load_global_var_dynamic() {
  emit_opcode(LOAD_GLOBAL_VAR_DYNAMIC);
  stack_.pop();
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::store_global_var(int global_id) {
  emit_possibly_wide(STORE_GLOBAL_VAR, global_id);
}

void Emitter::store_global_var_dynamic() {
  emit_opcode(STORE_GLOBAL_VAR_DYNAMIC);
  stack_.pop(2);
}

void Emitter::load_field(int n) {
  ASSERT(n >= 0);
  stack_.pop();
  stack_.push(ExpressionStack::OBJECT);

  if (n < 16) {
    int local;
    unsigned last = opcode_positions_.last();
    if (builder_[last] >= LOAD_LOCAL_0 && previous_opcode() <= LOAD_LOCAL_5) {
      ASSERT(last == position() - 1);
      local = builder_[last] - LOAD_LOCAL_0;
      builder_[last] = LOAD_FIELD_LOCAL;
      emit_uint8(n << 4 | local);
      return;
    } else if (last_is(LOAD_LOCAL, &local) && local < 16) {
      builder_[last] = LOAD_FIELD_LOCAL;
      builder_[last + 1] = n << 4 | local;
      return;
    } else if (last_is(POP_LOAD_LOCAL, &local) && local < 16) {
      builder_[last] = POP_LOAD_FIELD_LOCAL;
      builder_[last + 1] = n << 4 | local;
      return;
    }
  }
  emit_possibly_wide(LOAD_FIELD, n);
}

void Emitter::store_field(int n) {
  ASSERT(n >= 0);
  emit_possibly_wide(STORE_FIELD, n);
  ExpressionStack::Type type = stack_.type(0);
  stack_.pop();
  stack_.pop();  // Drop the instance.
  stack_.push(type);
}

void Emitter::load_local(int n) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  ExpressionStack::Type type = stack_.type(offset);
  stack_.push(type);
  emit_load_local(offset);
}

void Emitter::load_outer_local(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->height());
  ASSERT(outer_emitter->stack_.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() - n - 1;
  ExpressionStack::Type type = outer_emitter->stack_.type(offset);
  emit(LOAD_OUTER, offset);
  stack_.pop();  // The block reference.
  stack_.push(type);
}

void Emitter::load_parameter(int n, ExpressionStack::Type type) {
  ASSERT(n >= 0 && n < arity());
  int offset = height() + frame_size() + (arity() - n - 1);
  stack_.push(type);
  emit_load_local(offset);
}

void Emitter::load_outer_parameter(int n, ExpressionStack::Type type, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->arity());
  ASSERT(outer_emitter->stack_.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() + frame_size() + (outer_emitter->arity() - n - 1);
  emit(LOAD_OUTER, offset);
  stack_.pop();  // The block reference.
  stack_.push(type);
}

void Emitter::store_local(int n) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  emit(STORE_LOCAL, offset);
}

void Emitter::store_outer_local(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->height());
  ASSERT(outer_emitter->stack_.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() - n - 1;
  emit(STORE_OUTER, offset);
  stack_.pop();
}

void Emitter::store_parameter(int n) {
  ASSERT(n >= 0 && n < arity());
  int offset = arity() - n - 1;
  emit(STORE_LOCAL, offset + height() + frame_size());
}

void Emitter::store_outer_parameter(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->arity());
  ASSERT(outer_emitter->stack_.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->arity() - n - 1;
  emit(STORE_OUTER, offset + outer_emitter->height() + frame_size());
  stack_.pop();
}

void Emitter::load_block(int n) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  emit(LOAD_BLOCK, offset);
  stack_.push(ExpressionStack::BLOCK);
}

void Emitter::load_outer_block(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->height());
  ASSERT(outer_emitter->stack_.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() - n - 1;
  // The reference isn't yet encoded as block. That's why we need to call the
  //   LOAD_OUTER_BLOCK and not just `LOAD_OUTER`.
  ASSERT(outer_emitter->stack_.type(offset) == ExpressionStack::OBJECT);
  emit(LOAD_OUTER_BLOCK, offset);
  stack_.pop();  // The block reference.
  stack_.push(ExpressionStack::BLOCK);
}

void Emitter::pop(int n) {
  if (n == 0) return;
  ASSERT(n >= 0 && n <= height());
  unsigned last_pos = opcode_positions_.last();
  auto previous = previous_opcode();
  if (n == 1 &&
      (previous == STORE_LOCAL || previous == STORE_FIELD)) {
    if (previous == STORE_LOCAL) {
      builder_[last_pos] = STORE_LOCAL_POP;
    } else if (previous == STORE_FIELD) {
      builder_[last_pos] = STORE_FIELD_POP;
    }
  } else if (previous == POP || previous == POP_1) {
    int value = previous == POP ? builder_[last_pos + 1] : 1;
    int new_value = value + n;
    if (new_value <= MAX_BYTECODE_VALUE) {
      if (previous == POP) {
        builder_[last_pos + 1] = new_value;
      } else {
        builder_[last_pos] = POP;
        builder_.add(new_value);
      }
    } else if (n == 1) {
      emit_opcode(POP_1);
    } else {
      emit(POP, n);
    }
  } else if (n == 1) {
    emit_opcode(POP_1);
  } else {
    emit(POP, n);
  }
  stack_.pop(n);
}

void Emitter::allocate(int class_id) {
  ASSERT(class_id >= 0);
  emit_possibly_wide(ALLOCATE, class_id);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_global(int index, int arity, bool is_tail_call) {
  ASSERT(index >= 0);
  emit_opcode(is_tail_call ? INVOKE_STATIC_TAIL : INVOKE_STATIC);
  emit_uint16(index);
  // Format 2 replaces the frame: the frame stack knows its height and arity.
  if (is_tail_call && !is_format2()) {
    emit_uint8(height());
    emit_uint8(this->arity());
  }
  stack_.pop(arity);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_block(int arity) {
  ASSERT(arity >= 1);
  ASSERT(stack_.type(arity - 1) == ExpressionStack::BLOCK);
  emit(INVOKE_BLOCK, arity);
  stack_.pop(arity);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_virtual(Opcode opcode, int offset, int arity) {
  ASSERT(offset >= 0);
  ASSERT(arity >= 1);
  ASSERT(INVOKE_SIZE > INVOKE_AT_PUT);
  if (opcode >= INVOKE_EQ && opcode <= INVOKE_AT_PUT) {
    emit_opcode(opcode);
  } else if (opcode == INVOKE_VIRTUAL_GET || opcode == INVOKE_VIRTUAL_SET || opcode == INVOKE_SIZE) {
    emit_opcode(opcode);
    emit_uint16(offset);
  } else {
    emit_possibly_wide(opcode, arity - 1);
    emit_uint16(offset);
  }
  stack_.pop(arity);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_initializer_tail() {
  emit_opcode(INVOKE_INITIALIZER_TAIL);
  if (!is_format2()) {
    emit_uint8(height());
    emit_uint8(this->arity());
  }
  stack_.pop();
}

void Emitter::typecheck(Opcode opcode, int index, bool is_nullable) {
  int encoded = (index << 1) + (is_nullable ? 1 : 0);
  emit_possibly_wide(opcode, encoded);
  stack_.pop(1);
  stack_.push(ExpressionStack::OBJECT);
}

int Emitter::typecheck_local(int n, int index) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  return typecheck_local_at_offset(offset, index);
}

int Emitter::typecheck_parameter(int n, int index) {
  ASSERT(n >= 0 && n < arity());
  int offset = height() + frame_size() + (arity() - n - 1);
  return typecheck_local_at_offset(offset, index);
}

int Emitter::typecheck_local_at_offset(int offset, int index) {
  if (offset <= 0x07 && index <= 0x1F) {
    int encoded = (offset << 5) | index;
    emit(AS_LOCAL, encoded);
    return position();
  }
  emit_load_local(offset);
  stack_.push(ExpressionStack::OBJECT);
  Opcode opcode = AS_CLASS;
  bool is_nullable = false;
  typecheck(opcode, index, is_nullable);
  int result = position();
  pop(1);
  return result;
}

void Emitter::primitive(int module, int index) {
  ASSERT(height() == 0);  // Must be on empty stack.
  emit(PRIMITIVE, module);
  emit_uint16(index);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::branch(Condition condition, Label* label) {
  Opcode op;
  if (condition == UNCONDITIONAL) {
    op = label->is_bound() ? BRANCH_BACK : BRANCH;
  } else if (condition == IF_TRUE) {
    op = label->is_bound() ? BRANCH_BACK_IF_TRUE : BRANCH_IF_TRUE;
    stack_.pop();
  } else if (condition == IF_NOT_NULL) {
    op = label->is_bound() ? BRANCH_BACK_IF_NOT_NULL : BRANCH_IF_NOT_NULL;
    stack_.pop();
  } else {
    ASSERT(condition == IF_FALSE);
    op = label->is_bound() ? BRANCH_BACK_IF_FALSE: BRANCH_IF_FALSE;
    stack_.pop();
  }

  int position = this->position();
  if (label->is_bound()) {
    int offset = -(label->position() - position);
    ASSERT(offset >= 0);
    emit_opcode(op);
    emit_uint16(offset);
    // Format 2 finds the method from the frame stack.
    if (!is_format2()) emit_uint16(position);
  } else {
    label->use(position, height());
    emit_opcode(op);
    emit_uint16(0);
  }
}

void Emitter::invoke_lambda_tail(int parameters, int max_capture_count) {
  stack_.reserve(max_capture_count);
  if (is_format2()) {
    // The arguments are the parameters of the frame.
    ASSERT(parameters == arity() - 1);
    emit_opcode(INVOKE_LAMBDA_TAIL);
  } else {
    emit(INVOKE_LAMBDA_TAIL, parameters);
  }
}

void Emitter::ret() {
  emit_opcode(RETURN);
  if (is_format2()) return;
  emit_uint8(height());
  emit_uint8(arity());
}

void Emitter::ret_null() {
  int value;
  if (is_format2()) {
    // A return drops the whole frame, so a pop right before it is redundant.
    if (previous_opcode() == POP_1) {
      ASSERT(builder_.last() == POP_1);
      builder_.last() = RETURN_NULL;
    } else if (last_is(POP, &value)) {
      int last_pos = opcode_positions_.last();
      builder_[last_pos] = RETURN_NULL;
      builder_.remove_last();
    } else {
      emit_opcode(RETURN_NULL);
    }
    return;
  }
  if (previous_opcode() == POP_1) {
    ASSERT(builder_.last() == POP_1);
    builder_.last() = RETURN_NULL;
    emit_uint8(height() + 1);
    emit_uint8(arity());
  } else if (last_is(POP, &value)) {
    int last_pos = opcode_positions_.last();
    builder_[last_pos] = RETURN_NULL;
    ASSERT(last_pos + 1 == builder_.length() -1);
    builder_[last_pos + 1] = height() + value;
    emit_uint8(arity());
  } else {
    emit_opcode(RETURN_NULL);
    emit_uint8(height());
    emit_uint8(arity());
  }
}

void Emitter::nlr(int height, int arity) {
  if (is_format2()) {
    // The block reference identifies the frame to return from.
    emit_opcode(NON_LOCAL_RETURN);
    stack_.pop();
    return;
  }
  if (height >= 0x0f || arity >= 0x0f) {
    ASSERT(height <= MAX_USHORT_VALUE);
    ASSERT(arity <= MAX_USHORT_VALUE);
    emit_opcode(NON_LOCAL_RETURN_WIDE);
    emit_uint16(arity);
    emit_uint16(height);
  } else {
    ASSERT(height >= 0 && height < 0x0f);
    ASSERT(arity >= 0 && arity < 0x0f);
    emit(NON_LOCAL_RETURN, (height << 4) | arity);
  }
  stack_.pop();
}

void Emitter::register_absolute_reference(const AbsoluteReference& reference) {
  absolute_references_.add(reference);
}

void Emitter::nl_branch(AbsoluteLabel* label, int height_diff) {
  emit(NON_LOCAL_BRANCH, height_diff);
  absolute_uses_.add(label->use_absolute(position()));
  // Will be replaced once the global label knows its absolute position.
  emit_uint32(0);
  stack_.pop();
}

void Emitter::_throw() {
  if (is_format2()) {
    emit_opcode(THROW);
  } else {
    emit(THROW, 0);
  }
}

void Emitter::link() {
  ASSERT(!is_format2());
  emit(LINK, 0);
  remember(4);
}

void Emitter::try_finally() {
  ASSERT(is_format2());
  ASSERT(stack_.type(0) == ExpressionStack::OBJECT);  // The try block's method.
  emit_opcode(V2_TRY);
  // The finally code starts with the exception (or null), the unwinding
  // token and the reason.
  remember(3);
}

void Emitter::load_field_this(int n) {
  ASSERT(is_format2());
  ASSERT(n >= 0 && n <= MAX_BYTECODE_VALUE);
  emit(V2_LOAD_FIELD_THIS, n);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::loop_step(Opcode opcode, Label* body, int counter) {
  ASSERT(is_format2());
  ASSERT(opcode == V2_LOOP_REPEAT || opcode == V2_LOOP_ARRAY);
  ASSERT(body->is_bound());
  // The counter is a local or temporary; the block and limit may be
  // parameters.
  ASSERT(1 <= counter && counter < height() && counter + 2 <= MAX_BYTECODE_VALUE);
  // The taken step pops the top and pushes the block and the counter.
  ASSERT(body->height() == height() + 1);
  int position = this->position();
  int offset = position - body->position();
  ASSERT(0 < offset && offset <= MAX_USHORT_VALUE);
  emit_opcode(opcode);
  emit_uint16(offset);
  emit_uint8(counter);
  // Falling through pops the top.
  stack_.pop(1);
}

void Emitter::hash_find(Label* miss, int state, int hash) {
  ASSERT(is_format2());
  ASSERT(!miss->is_bound());
  ASSERT(0 <= state && state + 2 < height() && 0 <= hash && hash + 2 <= MAX_BYTECODE_VALUE);
  int position = this->position();
  // The miss target has the code pushed.
  miss->use(position, height() + 1);
  emit_opcode(V2_HASH_FIND);
  emit_uint16(0);
  emit_uint8(state);
  emit_uint8(hash);
  // Falling through pushes the key and its position.
  stack_.push(ExpressionStack::OBJECT);
  stack_.push(ExpressionStack::OBJECT);
}

void Emitter::store_field_this(int n) {
  ASSERT(is_format2());
  ASSERT(n >= 0 && n <= MAX_BYTECODE_VALUE);
  emit(V2_STORE_FIELD_THIS, n);
  // The value stays on the stack.
}

bool Emitter::ends_with_terminator() {
  switch (previous_opcode()) {
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

void Emitter::unlink() {
  emit(UNLINK, 0);
  stack_.pop();
}

void Emitter::unwind() {
  emit_opcode(UNWIND);
  stack_.pop(3);
}

void Emitter::identical() {
  emit_opcode(IDENTICAL);
  stack_.pop(1);
}

void Emitter::halt(int yield) {
  emit(HALT, yield);
  if (yield == 0) {
    stack_.push(ExpressionStack::OBJECT);
  }
}

void Emitter::intrinsic_smi_repeat() {
  emit_opcode(INTRINSIC_SMI_REPEAT);
  stack_.pop(1);
}

void Emitter::intrinsic_array_do() {
  emit_opcode(INTRINSIC_ARRAY_DO);
  stack_.pop(1);
}

void Emitter::intrinsic_hash_find() {
  emit_opcode(INTRINSIC_HASH_FIND);
  stack_.pop(7);
}

void Emitter::intrinsic_hash_do() {
  emit_opcode(INTRINSIC_HASH_DO);
  stack_.pop(1);
}


} // namespace toit::compiler
} // namespace toit

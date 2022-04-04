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
#include "../objects_inline.h"
#include "../interpreter.h"
#include "limits.h"

namespace toit {
namespace compiler {

static const int MIN_BYTECODE_VALUE = 0;
static const int MAX_BYTECODE_VALUE = UCHAR_MAX;
// TODO(Lau): Inline max value:
static const int MAX_USHORT_VALUE   = USHRT_MAX;

inline void Emitter::emit(Opcode opcode, int value) {
  ASSERT(MIN_BYTECODE_VALUE <= value && value <= MAX_BYTECODE_VALUE);
  emit_opcode(opcode);
  emit_uint8(value);
}

inline void Emitter::emit_opcode(Opcode opcode) {
  _opcode_positions.add(position());
  _builder.add(opcode);
}

inline void Emitter::emit_uint8(uint8 value) {
  _builder.add(value & 0xff);
}

inline void Emitter::emit_uint16(uint16 value) {
  _builder.add(value & 0xff);
  _builder.add(value >> 8);
}

inline void Emitter::emit_uint16_at(int offset, uint16 value) {
  _builder[offset] = value & 0xff;
  _builder[offset + 1] = value >> 8;
}

inline void Emitter::emit_uint32(uint32 value) {
  _builder.add((value >>  0) & 0xff);
  _builder.add((value >>  8) & 0xff);
  _builder.add((value >> 16) & 0xff);
  _builder.add((value >> 24) & 0xff);
}

List<uint8> Emitter::bytecodes() {
  return _builder.build();
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
    ASSERT(_opcode_positions.last() == index);
    _builder[index] = POP_LOAD_LOCAL;
    emit_uint8(offset);
  } else if (offset <= MAX_BYTECODE_VALUE &&
      last_is(POP, &value) &&
      value == 2) {
    // We change this to POP_1, followed by POP_LOAD_LOCAL, as this make
    //   other peepholes easier to implement.
    int previous_position = _opcode_positions.last();
    _builder[previous_position] = POP_1;
    ASSERT(_builder.last() == 2);  // The POP value.
    _builder.remove_last();
    emit(POP_LOAD_LOCAL, offset);
  } else if (offset >= 0 && offset <= 5) {
    emit_opcode(static_cast<Opcode>(LOAD_LOCAL_0 + offset));
  } else {
    emit_possibly_wide(LOAD_LOCAL, offset);
  }
}

bool Emitter::last_is(Opcode opcode, int* value) {
  if (previous_opcode() != opcode) return false;
  if (value) *value = _builder[_opcode_positions.last()  + 1];
  return true;
}

Opcode Emitter::previous_opcode(int n) {
  if (_opcode_positions.length() <= n) return ILLEGAL_END;
  auto position = _opcode_positions[_opcode_positions.length() - 1 - n];
  if (position < _last_bound) return ILLEGAL_END;
  return static_cast<Opcode>(_builder[position]);
}

void Emitter::bind(Label* label) {
  ASSERT(!label->is_bound());
  int position = this->position();
  for (int i = 0; i < label->uses(); i++) {
    int use = label->use_at(i);
    int offset = position - use;
    ASSERT(_builder[use + 1] == 0 && _builder[use + 2] == 0);
    emit_uint16_at(use + 1, offset);
  }
  label->bind(position, height());
  _last_bound = position;
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
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::load_n_smis(int n) {
  ASSERT(0 < n && n < 0x100);
  emit(LOAD_SMIS_0, n);
  for (int i = 0; i < n; i++) {
    _stack.push(ExpressionStack::OBJECT);
  }
}

void Emitter::load_literal(int index) {
  ASSERT(index >= 0);
  emit_possibly_wide(LOAD_LITERAL, index);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::load_null() {
  emit_opcode(LOAD_NULL);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::load_global_var(int global_id, bool is_lazy) {
  emit_possibly_wide(is_lazy ? LOAD_GLOBAL_VAR_LAZY : LOAD_GLOBAL_VAR, global_id);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::load_global_var_dynamic() {
  emit_opcode(LOAD_GLOBAL_VAR_DYNAMIC);
  _stack.pop();
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::store_global_var(int global_id) {
  emit_possibly_wide(STORE_GLOBAL_VAR, global_id);
}

void Emitter::store_global_var_dynamic() {
  emit_opcode(STORE_GLOBAL_VAR_DYNAMIC);
  _stack.pop(2);
}

void Emitter::load_field(int n) {
  ASSERT(n >= 0);
  _stack.pop();
  _stack.push(ExpressionStack::OBJECT);

  if (n < 16) {
    int local;
    unsigned last = _opcode_positions.last();
    if (_builder[last] >= LOAD_LOCAL_0 && previous_opcode() <= LOAD_LOCAL_5) {
      ASSERT(last == position() - 1);
      local = _builder[last] - LOAD_LOCAL_0;
      _builder[last] = LOAD_FIELD_LOCAL;
      emit_uint8(n << 4 | local);
      return;
    } else if (last_is(LOAD_LOCAL, &local) && local < 16) {
      _builder[last] = LOAD_FIELD_LOCAL;
      _builder[last + 1] = n << 4 | local;
      return;
    } else if (last_is(POP_LOAD_LOCAL, &local) && local < 16) {
      _builder[last] = POP_LOAD_FIELD_LOCAL;
      _builder[last + 1] = n << 4 | local;
      return;
    }
  }
  emit_possibly_wide(LOAD_FIELD, n);
}

void Emitter::store_field(int n) {
  ASSERT(n >= 0);
  emit_possibly_wide(STORE_FIELD, n);
  ExpressionStack::Type type = _stack.type(0);
  _stack.pop();
  _stack.pop();  // Drop the instance.
  _stack.push(type);
}

void Emitter::load_local(int n) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  ExpressionStack::Type type = _stack.type(offset);
  _stack.push(type);
  emit_load_local(offset);
}

void Emitter::load_outer_local(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->height());
  ASSERT(outer_emitter->_stack.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() - n - 1;
  ExpressionStack::Type type = outer_emitter->_stack.type(offset);
  emit(LOAD_OUTER, offset);
  _stack.pop();  // The block reference.
  _stack.push(type);
}

void Emitter::load_parameter(int n, ExpressionStack::Type type) {
  ASSERT(n >= 0 && n < arity());
  int frame_size = Interpreter::FRAME_SIZE;
  int offset = height() + frame_size + (arity() - n - 1);
  _stack.push(type);
  emit_load_local(offset);
}

void Emitter::load_outer_parameter(int n, ExpressionStack::Type type, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->arity());
  ASSERT(outer_emitter->_stack.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int frame_size = Interpreter::FRAME_SIZE;
  int offset = outer_emitter->height() + frame_size + (outer_emitter->arity() - n - 1);
  emit(LOAD_OUTER, offset);
  _stack.pop();  // The block reference.
  _stack.push(type);
}

void Emitter::store_local(int n) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  emit(STORE_LOCAL, offset);
}

void Emitter::store_outer_local(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->height());
  ASSERT(outer_emitter->_stack.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() - n - 1;
  emit(STORE_OUTER, offset);
  _stack.pop();
}

void Emitter::store_parameter(int n) {
  ASSERT(n >= 0 && n < arity());
  int offset = arity() - n - 1;
  int frame_size = Interpreter::FRAME_SIZE;
  emit(STORE_LOCAL, offset + height() + frame_size);
}

void Emitter::store_outer_parameter(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->arity());
  ASSERT(outer_emitter->_stack.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->arity() - n - 1;
  int frame_size = Interpreter::FRAME_SIZE;
  emit(STORE_OUTER, offset + outer_emitter->height() + frame_size);
  _stack.pop();
}

void Emitter::load_block(int n) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  emit(LOAD_BLOCK, offset);
  _stack.push(ExpressionStack::BLOCK);
}

void Emitter::load_outer_block(int n, Emitter* outer_emitter) {
  ASSERT(n >= 0 && n < outer_emitter->height());
  ASSERT(outer_emitter->_stack.type(0) == ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);
  int offset = outer_emitter->height() - n - 1;
  // The reference isn't yet encoded as block. That's why we need to call the
  //   LOAD_OUTER_BLOCK and not just `LOAD_OUTER`.
  ASSERT(outer_emitter->_stack.type(offset) == ExpressionStack::OBJECT);
  emit(LOAD_OUTER_BLOCK, offset);
  _stack.pop();  // The block reference.
  _stack.push(ExpressionStack::BLOCK);
}

void Emitter::pop(int n) {
  if (n == 0) return;
  ASSERT(n >= 0 && n <= height());
  unsigned last_pos = _opcode_positions.last();
  auto previous = previous_opcode();
  if (n == 1 &&
      (previous == STORE_LOCAL || previous == STORE_FIELD)) {
    if (previous == STORE_LOCAL) {
      _builder[last_pos] = STORE_LOCAL_POP;
    } else if (previous == STORE_FIELD) {
      _builder[last_pos] = STORE_FIELD_POP;
    }
  } else if (previous == POP || previous == POP_1) {
    int value = previous == POP ? _builder[last_pos + 1] : 1;
    int new_value = value + n;
    if (new_value <= MAX_BYTECODE_VALUE) {
      if (previous == POP) {
        _builder[last_pos + 1] = new_value;
      } else {
        _builder[last_pos] = POP;
        _builder.add(new_value);
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
  _stack.pop(n);
}

void Emitter::allocate(int class_id) {
  ASSERT(class_id >= 0);
  emit_possibly_wide(ALLOCATE, class_id);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_global(int index, int arity, bool is_tail_call) {
  ASSERT(index >= 0);
  emit_opcode(is_tail_call ? INVOKE_STATIC_TAIL : INVOKE_STATIC);
  emit_uint16(index);
  if (is_tail_call) {
    emit_uint8(height());
    emit_uint8(this->arity());
  }
  _stack.pop(arity);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_block(int arity) {
  ASSERT(arity >= 1);
  ASSERT(_stack.type(arity - 1) == ExpressionStack::BLOCK);
  emit(INVOKE_BLOCK, arity);
  _stack.pop(arity);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_virtual(Opcode opcode, int offset, int arity) {
  ASSERT(offset >= 0);
  ASSERT(arity >= 1);
  if (opcode >= INVOKE_EQ && opcode <= INVOKE_AT_PUT) {
    emit_opcode(opcode);
  } else if (opcode == INVOKE_VIRTUAL_GET || opcode == INVOKE_VIRTUAL_SET) {
    emit_opcode(opcode);
    emit_uint16(offset);
  } else {
    emit_possibly_wide(opcode, arity - 1);
    emit_uint16(offset);
  }
  _stack.pop(arity);
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::invoke_initializer_tail() {
  emit_opcode(INVOKE_INITIALIZER_TAIL);
  emit_uint8(height());
  emit_uint8(this->arity());
  _stack.pop();
}

void Emitter::typecheck(Opcode opcode, int index, bool is_nullable) {
  int encoded = (index << 1) + (is_nullable ? 1 : 0);
  emit_possibly_wide(opcode, encoded);
  _stack.pop(1);
  _stack.push(ExpressionStack::OBJECT);
}

int Emitter::typecheck_local(int n, int index) {
  ASSERT(n >= 0 && n < height());
  int offset = height() - n - 1;
  return typecheck_local_at_offset(offset, index);
}

int Emitter::typecheck_parameter(int n, int index) {
  ASSERT(n >= 0 && n < arity());
  int frame_size = Interpreter::FRAME_SIZE;
  int offset = height() + frame_size + (arity() - n - 1);
  return typecheck_local_at_offset(offset, index);
}

int Emitter::typecheck_local_at_offset(int offset, int index) {
  if (offset <= 0x07 && index <= 0x1F) {
    int encoded = (offset << 5) | index;
    emit(AS_LOCAL, encoded);
    return position();
  }
  emit_load_local(offset);
  _stack.push(ExpressionStack::OBJECT);
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
  _stack.push(ExpressionStack::OBJECT);
}

void Emitter::branch(Condition condition, Label* label) {
  Opcode op;
  if (condition == UNCONDITIONAL) {
    op = label->is_bound() ? BRANCH_BACK : BRANCH;
  } else if (condition == IF_TRUE) {
    op = label->is_bound() ? BRANCH_BACK_IF_TRUE : BRANCH_IF_TRUE;
    _stack.pop();
  } else {
    ASSERT(condition == IF_FALSE);
    op = label->is_bound() ? BRANCH_BACK_IF_FALSE: BRANCH_IF_FALSE;
    _stack.pop();
  }

  int position = this->position();
  if (label->is_bound()) {
    int offset = -(label->position() - position);
    ASSERT(offset >= 0);
    emit_possibly_wide(op, offset);
  } else {
    label->use(position, height());
    emit_opcode(op);
    emit_uint16(0);
  }
}

void Emitter::invoke_lambda_tail(int parameters, int max_capture_count) {
  _stack.reserve(max_capture_count);
  emit(INVOKE_LAMBDA_TAIL, parameters);
}

void Emitter::ret() {
  emit_opcode(RETURN);
  emit_uint8(height());
  emit_uint8(arity());
}

void Emitter::ret_null() {
  int value;
  if (previous_opcode() == POP_1) {
    ASSERT(_builder.last() == POP_1);
    _builder.last() = RETURN_NULL;
    emit_uint8(height() + 1);
    emit_uint8(arity());
  } else if (last_is(POP, &value)) {
    int last_pos = _opcode_positions.last();
    _builder[last_pos] = RETURN_NULL;
    ASSERT(last_pos + 1 == _builder.length() -1);
    _builder[last_pos + 1] = height() + value;
    emit_uint8(arity());
  } else {
    emit_opcode(RETURN_NULL);
    emit_uint8(height());
    emit_uint8(arity());
  }
}

void Emitter::nlr(int height, int arity) {
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
  _stack.pop();
}

void Emitter::register_absolute_reference(const AbsoluteReference& reference) {
  _absolute_references.add(reference);
}

void Emitter::nl_branch(AbsoluteLabel* label, int height_diff) {
  emit(NON_LOCAL_BRANCH, height_diff);
  _absolute_uses.add(label->use_absolute(position()));
  // Will be replaced once the global label knows its absolute position.
  emit_uint32(0);
  _stack.pop();
}

void Emitter::_throw() {
  emit(THROW, 0);
}

void Emitter::link() {
  emit(LINK, 0);
  remember(4);
}

void Emitter::unlink() {
  emit(UNLINK, 0);
  _stack.pop();
}

void Emitter::unwind() {
  emit_opcode(UNWIND);
   _stack.pop(3);
}

void Emitter::halt(int yield) {
  emit(HALT, yield);
  if (yield == 0) {
    _stack.push(ExpressionStack::OBJECT);
  }
}

void Emitter::intrinsic_smi_repeat() {
  emit_opcode(INTRINSIC_SMI_REPEAT);
  _stack.pop(1);
}

void Emitter::intrinsic_array_do() {
  emit_opcode(INTRINSIC_ARRAY_DO);
  _stack.pop(1);
}

void Emitter::intrinsic_hash_find() {
  emit_opcode(INTRINSIC_HASH_FIND);
  _stack.pop(7);
}

void Emitter::intrinsic_hash_do() {
  emit_opcode(INTRINSIC_HASH_DO);
  _stack.pop(1);
}


} // namespace toit::compiler
} // namespace toit

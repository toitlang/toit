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

#pragma once

#include <vector>

#include "../top.h"
#include "../bytecodes.h"

#include "ast.h"
#include "label.h"
#include "list.h"

namespace toit {
namespace compiler {

class Compiler;

class ExpressionStack {
 public:
  enum Type {
    OBJECT,
    BLOCK,
    BLOCK_CONSTRUCTION_TOKEN
  };

  ExpressionStack() : _data(), _types(_data, CAPACITY), _height(0) { }

  int height() const { return _height; }
  int max_height() const { return _max_height; }

  Type type(int n) const { return _types[_height - n - 1]; }

  void push(Type type) {
    _types[_height++] = type;
    _max_height = std::max(_max_height, _height);
  }
  void pop(int n = 1) { ASSERT(n >= 0 && n <= _height); _height -= n; }

  void reserve(int count) {
    _max_height = std::max(_max_height, _height + count);
  }

 private:
  static const int CAPACITY = 128;
  Type _data[CAPACITY];

  List<Type> _types;
  int _height;
  int _max_height = 0;
};

class Emitter {
 public:
  explicit Emitter(int arity)
      : _arity(arity)
      , _builder()
      , _last_bound(0) { }

  enum Condition {
    UNCONDITIONAL,
    IF_TRUE,
    IF_FALSE
  };

  List<uint8> bytecodes();

  unsigned position() const { return _builder.length(); }

  int arity() const { return _arity; }
  int height() const { return _stack.height(); }
  int max_height() const { return _stack.max_height(); }

  void bind(Label* label);

  void load_integer(word value);
  void load_n_smis(int n);
  void load_literal(int index);

  void load_null();
  void load_true() { load_literal(0); }
  void load_false() { load_literal(1); }

  void load_global_var(int global_id, bool is_lazy);
  void load_global_var_dynamic();
  void store_global_var(int global_id);
  void store_global_var_dynamic();

  void load_field(int n);
  void store_field(int n);

  void load_local(int n);
  void load_outer_local(int n, Emitter* outer_emitter);
  void load_parameter(int n, ExpressionStack::Type type);
  void load_outer_parameter(int n, ExpressionStack::Type type, Emitter* outer_emitter);
  void load_outer(int n, ExpressionStack::Type type);

  void store_local(int n);
  void store_outer_local(int n, Emitter* outer_emitter);
  void store_parameter(int n);
  void store_outer_parameter(int n, Emitter* outer_emitter);
  void store_outer(int n);

  void load_block(int n);
  void load_outer_block(int n, Emitter* outer_emitter);

  void pop(int n);
  List<ExpressionStack::Type> pop_return_types(int n);
  void dup() { load_local(height() - 1); }

  void forget(int n) { _stack.pop(n); }
  void remember(int n, ExpressionStack::Type type = ExpressionStack::OBJECT) {
    ASSERT(n >= 0);
    for (int i = 0; i < n; i++) {
      _stack.push(type);
    }
  }
  void remember(List<ExpressionStack::Type> types) {
    for (int i = 0; i < types.length(); i++) {
      _stack.push(types[i]);
    }
  }
  List<ExpressionStack::Type> stack_types(int n) {
    auto result = ListBuilder<ExpressionStack::Type>::allocate(n);
    for (int i = 0; i < n; i++) {
      result[i] = _stack.type(n - i - 1);
    }
    return result;
  }

  void allocate(int class_id);

  void invoke_global(int index, int arity, bool is_tail_call = false);
  void invoke_virtual(Opcode opcode, int offset, int arity);

  void invoke_block(int arity);
  void invoke_lambda_tail(int parameters, int max_capture_count);
  void invoke_initializer_tail();

  void typecheck(Opcode opcode, int index, bool is_nullable);
  // Returns the bytecode_position just after the typecheck.
  int typecheck_local(int n, int index);
  int typecheck_parameter(int n, int index);

  void branch(Condition condition, Label* label);

  void primitive(int module, int index);

  void ret();
  void ret_null();
  void nlr(int height, int arity);

  void register_absolute_reference(const AbsoluteReference& reference);
  void nl_branch(AbsoluteLabel* label, int height_diff);

  void _throw();
  void link();
  void unlink();
  void unwind();

  void halt(int yield);

  void intrinsic_smi_repeat();
  void intrinsic_array_do();
  void intrinsic_hash_find();
  void intrinsic_hash_do();

  List<AbsoluteReference> build_absolute_references() { return _absolute_references.build(); }
  List<AbsoluteUse*> build_absolute_uses() { return _absolute_uses.build(); }

  // Returns a previous opcode.
  // If n == 0, returns the last emitted bytecode.
  // If the previous bytecode doesn't exist, or is not safe to use (because of
  //   a label), then returns ILLEGAL_END.
  toit::Opcode previous_opcode(int n = 0);

 private:
  const int _arity;
  ListBuilder<uint8> _builder;
  ListBuilder<AbsoluteReference> _absolute_references;
  ListBuilder<AbsoluteUse*> _absolute_uses;

  // Support for peephole optimizations. We keep track of bound labels, so we
  // don't optimize across a branch target and we know the precise start position
  // for all opcodes in the emitted code.
  ListBuilder<unsigned> _opcode_positions;
  unsigned _last_bound;

  ExpressionStack _stack;

  word extend(word value);

  void emit(Opcode opcode, int value);

  void emit_opcode(Opcode opcode);
  void emit_uint8(uint8 value);
  void emit_uint16(uint16 value);
  void emit_uint16_at(int offset, uint16 value);
  void emit_uint32(uint32 value);

  void emit_possibly_wide(Opcode small, word value);
  void emit_load_local(int offset);
  bool last_is(Opcode opcode, int* value);
  int typecheck_local_at_offset(int offset, int index);
};

} // namespace toit::compiler
} // namespace toit

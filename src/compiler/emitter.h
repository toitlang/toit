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

  ExpressionStack() : data_(), types_(data_, CAPACITY), height_(0) {}

  int height() const { return height_; }
  int max_height() const { return max_height_; }

  Type type(int n) const { return types_[height_ - n - 1]; }

  void push(Type type) {
    types_[height_++] = type;
    max_height_ = std::max(max_height_, height_);
  }
  void pop(int n = 1) { ASSERT(n >= 0 && n <= height_); height_ -= n; }

  void reserve(int count) {
    max_height_ = std::max(max_height_, height_ + count);
  }

 private:
  static const int CAPACITY = 128;
  Type data_[CAPACITY];

  List<Type> types_;
  int height_;
  int max_height_ = 0;
};

class Emitter {
 public:
  explicit Emitter(int arity)
      : arity_(arity)
      , builder_()
      , last_bound_(0) {}

  enum Condition {
    UNCONDITIONAL,
    IF_TRUE,
    IF_FALSE,
    IF_NOT_NULL,
  };

  List<uint8> bytecodes();

  unsigned position() const { return builder_.length(); }

  int arity() const { return arity_; }
  int height() const { return stack_.height(); }
  int max_height() const { return stack_.max_height(); }

  void bind(Label* label);

  void load_integer(word value);
  void load_n_smis(int n);
  void load_literal(int index);
  void load_method(int offset);

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

  void forget(int n) { stack_.pop(n); }
  void remember(int n, ExpressionStack::Type type = ExpressionStack::OBJECT) {
    ASSERT(n >= 0);
    for (int i = 0; i < n; i++) {
      stack_.push(type);
    }
  }
  void remember(List<ExpressionStack::Type> types) {
    for (int i = 0; i < types.length(); i++) {
      stack_.push(types[i]);
    }
  }
  List<ExpressionStack::Type> stack_types(int n) {
    auto result = ListBuilder<ExpressionStack::Type>::allocate(n);
    for (int i = 0; i < n; i++) {
      result[i] = stack_.type(n - i - 1);
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
  // Format 2: TRY on the try block's method on top of the stack.
  void try_finally();
  void load_field_this(int n);
  // Format 2, proposal (format note 19): a loop step, V2_LOOP_REPEAT or
  // V2_LOOP_ARRAY. The counter is slot [counter] from the top (before the
  // step pops the top), the block the slot above it, the limit (and for
  // LOOP_ARRAY the array) the ones above that; [body] is the bound
  // INVOKE_BLOCK the taken step branches back to.
  void loop_step(Opcode opcode, Label* body, int counter);
  // Format 2, proposal (format note 19): HASH_FIND with the probe state in
  // slots [state] .. [state] + 2 from the top, the hash in slot [hash] and
  // the collection in [hash] + 2. Falls through with the candidate key and
  // its position pushed; branches to [miss] with the code pushed.
  void hash_find(Label* miss, int state, int hash);
  void store_field_this(int n);
  // Whether the code ends with an instruction that does not continue with
  // the next one, and no label is bound after it.
  bool ends_with_terminator();
  void unlink();
  void unwind();

  void identical();

  void halt(int yield);

  void intrinsic_smi_repeat();
  void intrinsic_array_do();
  void intrinsic_hash_find();
  void intrinsic_hash_do();

  // Format 3 (verified/spec/format/22-format3-branches-frames.md): replaces
  // every BRANCH .. BRANCH_IF_NOT_NULL and BRANCH_BACK whose distance fits a
  // byte by its two-byte short form, and recomputes every distance in the
  // code (branches, loop steps, HASH_FIND). Distances only shrink when
  // instructions do, so the fixpoint is found by starting with every
  // candidate short and making long the ones that do not fit, until none
  // changes. The positions of the absolute uses and references move with
  // the code; other recorded positions go through [relocated]. Call once,
  // after the last instruction.
  void relax_branches();
  // The position after [relax_branches] of the code at [position] before
  // it (an instruction boundary, the end, or an operand of an instruction
  // that keeps its size).
  int relocated(int position) const;

  List<AbsoluteReference> build_absolute_references() { return absolute_references_.build(); }
  List<AbsoluteUse*> build_absolute_uses() { return absolute_uses_.build(); }

  // Returns a previous opcode.
  // If n == 0, returns the last emitted bytecode.
  // If the previous bytecode doesn't exist, or is not safe to use (because of
  //   a label), then returns ILLEGAL_END.
  toit::Opcode previous_opcode(int n = 0);

 private:
  const int arity_;
  ListBuilder<uint8> builder_;
  ListBuilder<AbsoluteReference> absolute_references_;
  ListBuilder<AbsoluteUse*> absolute_uses_;

  // Support for peephole optimizations. We keep track of bound labels, so we
  // don't optimize across a branch target and we know the precise start position
  // for all opcodes in the emitted code.
  ListBuilder<unsigned> opcode_positions_;
  unsigned last_bound_;

  ExpressionStack stack_;

  // Old position -> new position, after [relax_branches] (empty before).
  std::vector<int> relocation_;

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

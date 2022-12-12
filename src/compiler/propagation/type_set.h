// Copyright (C) 2022 Toitware ApS.
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

#include <string>

#include "../../top.h"
#include "../../objects.h"
#include "../../program.h"

namespace toit {
namespace compiler {

class BlockTemplate;

class TypeSet {
 public:
  class Iterator {
   public:
    Iterator(TypeSet type, int words_per_type)
        : cursor_(type.bits_)
        , end_(&type.bits_[words_per_type - 1]) {
      ASSERT(!type.is_block());
      uword bits = *cursor_;
      // The first bit of a type set is used as a marker and
      // guaranteed to be 0 for non-block typesets.
      // The base is thus -1.
      ASSERT((bits & 1) == 0);
      int base = -1;
      while (bits == 0 && cursor_ != end_) {
        bits = *(++cursor_);
        base += WORD_BIT_SIZE;
      }
      bits_ = bits;
      base_ = base;
    }

    bool has_next() const { return bits_ != 0; }

    unsigned next() {
      ASSERT(has_next());
      uword bits = bits_;
      // Compute the index of the next bit by counting
      // trailing zeros (ctz).
      int index = Utils::ctz(bits);
      int base = base_;
      unsigned result = index + base;
      bits &= ~(static_cast<uword>(1) << index);
      while (bits == 0 && cursor_ != end_) {
        bits = *(++cursor_);
        base += WORD_BIT_SIZE;
      }
      bits_ = bits;
      base_ = base;
      return result;
    }

   private:
    uword bits_;
    int base_;  // The class-index of the first bit in bits_.
    uword* cursor_;
    uword* const end_;
  };

  TypeSet(const TypeSet& other)
      : bits_(other.bits_) {}

  static TypeSet invalid() {
    return TypeSet(null);
  }

  bool is_valid() const {
    return bits_ != null;
  }

  bool is_block() const {
    return bits_[0] == 1;
  }

  int size(int words_per_type) const;
  bool is_empty(int words_per_type) const;
  bool is_any(Program* program) const;

  BlockTemplate* block() const {
    ASSERT(is_block());
    return reinterpret_cast<BlockTemplate*>(bits_[1]);
  }

  void set_block(BlockTemplate* block) {
    bits_[0] = 1;
    bits_[1] = reinterpret_cast<uword>(block);
  }

  bool contains(unsigned type) const {
    ASSERT(!is_block());
    unsigned entry = type + 1;
    uword old_bits = bits_[entry / WORD_BIT_SIZE];
    uword mask = static_cast<uword>(1) << (entry % WORD_BIT_SIZE);
    return (old_bits & mask) != 0;
  }

  bool contains_all(TypeSet other, int words) const {
    ASSERT(!is_block());
    ASSERT(!other.is_block());
    for (int i = 0; i < words; i++) {
      uword old_bits = bits_[i];
      uword new_bits = old_bits | other.bits_[i];
      if (new_bits != old_bits) return false;
    }
    return true;
  }

  bool contains_null(Program* program) const { return contains_instance(program->null_class_id()); }
  bool contains_instance(Smi* class_id) const { return contains(class_id->value()); }

  bool add(unsigned type) {
    ASSERT(!is_block());
    unsigned entry = type + 1;
    unsigned index = entry / WORD_BIT_SIZE;
    uword old_bits = bits_[index];
    uword mask = static_cast<uword>(1) << (entry % WORD_BIT_SIZE);
    bits_[index] = old_bits | mask;
    return (old_bits & mask) != 0;
  }

  void add_any(Program* program) { add_range(0, program->class_bits.length()); }
  bool add_array(Program* program) { return add_instance(program->array_class_id()); }
  bool add_byte_array(Program* program) { return add_instance(program->byte_array_class_id()); }
  bool add_float(Program* program) { return add_instance(program->double_class_id()); }
  bool add_instance(Smi* class_id) { return add(class_id->value()); }
  bool add_null(Program* program) { return add_instance(program->null_class_id()); }
  bool add_smi(Program* program) { return add_instance(program->smi_class_id()); }
  bool add_string(Program* program) { return add_instance(program->string_class_id()); }
  bool add_task(Program* program) { return add_instance(program->task_class_id()); }

  bool add_int(Program* program);
  bool add_bool(Program* program);
  void add_range(unsigned start, unsigned end);

  void add_all_also_blocks(TypeSet other, int words);

  bool add_all(TypeSet other, int words) {
    ASSERT(!is_block());
    ASSERT(!other.is_block());
    bool added = false;
    for (int i = 0; i < words; i++) {
      uword old_bits = bits_[i];
      uword new_bits = old_bits | other.bits_[i];
      added = added || (new_bits != old_bits);
      bits_[i] = new_bits;
    }
    return added;
  }

  void remove(unsigned type) {
    ASSERT(!is_block());
    unsigned entry = type + 1;
    unsigned index = entry / WORD_BIT_SIZE;
    uword old_bits = bits_[index];
    uword mask = static_cast<uword>(1) << (entry % WORD_BIT_SIZE);
    bits_[index] = old_bits & ~mask;
  }

  void remove_null(Program* program) { return remove_instance(program->null_class_id()); }
  void remove_instance(Smi* class_id) { return remove(class_id->value()); }
  void remove_range(unsigned start, unsigned end);

  bool remove_typecheck_class(Program* program, int index, bool is_nullable);
  bool remove_typecheck_interface(Program* program, int index, bool is_nullable);

  void clear(int words) {
    memset(bits_, 0, words * WORD_SIZE);
    ASSERT(!is_block());
  }

  std::string as_json(Program* program) const;

  void print(Program* program, const char* banner);

  static int words_per_type(Program* program) {
    int bits = program->class_bits.length() + 1;  // Need one extra bit to recognize blocks.
    int words_per_type = (bits + WORD_BIT_SIZE - 1) / WORD_BIT_SIZE;
    return Utils::max(words_per_type, 2);  // Need at least two words for block types.
  }

 private:
  explicit TypeSet(uword* bits)
      : bits_(bits) {}

  uword* const bits_;

  friend class TypeStack;
  friend class TypeVariable;
};

}  // namespace toit::compiler
}  // namespace toit

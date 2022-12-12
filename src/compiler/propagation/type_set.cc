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

#include "type_set.h"

#include <sstream>

namespace toit {
namespace compiler {

void TypeSet::print(Program* program, const char* banner) {
  printf("TypeSet(%s) = {", banner);
  if (is_block()) {
    printf(" block=%p", block());
  } else {
    bool first = true;
    // TODO(kasper): Avoid re-computing the words per type here.
    Iterator it(*this, words_per_type(program));
    while (it.has_next()) {
      unsigned id = it.next();
      if (first) printf(" ");
      else printf(", ");
      printf("%d", id);
      first = false;
    }
  }
  printf(" }");
}

std::string TypeSet::as_json(Program* program) const {
  if (is_block()) {
    return "\"[]\"";
  } else if (is_any(program)) {
    return "\"*\"";
  }

  std::stringstream result;
  result << "[";
  bool first = true;
  // TODO(kasper): Avoid re-computing the words per type here.
  Iterator it(*this, words_per_type(program));
  while (it.has_next()) {
    unsigned id = it.next();
    if (first) {
      first = false;
    } else {
      result << ",";
    }
    result << id;
  }
  result << "]";
  return result.str();
}

int TypeSet::size(int words_per_type) const {
  if (is_block()) return 1;
  int result = 0;
  for (int i = 0; i < words_per_type; i++) {
    result += Utils::popcount(bits_[i]);
  }
  return result;
}

bool TypeSet::is_empty(int words_per_type) const {
  if (is_block()) return false;
  for (int i = 0; i < words_per_type; i++) {
    if (bits_[i] != 0) return false;
  }
  return true;
}

bool TypeSet::is_any(Program* program) const {
  if (is_block()) return false;
  // TODO(kasper): Avoid re-computing the words per type here.
  return size(words_per_type(program)) == program->class_bits.length();
}

bool TypeSet::add_int(Program* program) {
  bool result = add_instance(program->smi_class_id());
  result = add_instance(program->large_integer_class_id()) || result;
  return result;
}

bool TypeSet::add_bool(Program* program) {
  bool result = add_instance(program->true_class_id());
  result = add_instance(program->false_class_id()) || result;
  return result;
}

void TypeSet::add_range(unsigned start, unsigned end) {
  int size = end - start;
  int from = start + 1;  //
  uword* data = &bits_[from / WORD_BIT_SIZE];
  Utils::mark_bits(data, from % WORD_BIT_SIZE, size);
}

void TypeSet::remove_range(unsigned start, unsigned end) {
  int size = end - start;
  int from = start + 1;  //
  uword* data = &bits_[from / WORD_BIT_SIZE];
  Utils::clear_bits(data, from % WORD_BIT_SIZE, size);
}

bool TypeSet::remove_typecheck_class(Program* program, int index, bool is_nullable) {
  unsigned start = program->class_check_ids[2 * index];
  unsigned end = program->class_check_ids[2 * index + 1];
  bool contains_null_before = contains_null(program);
  remove_range(0, start);
  remove_range(end, program->class_bits.length());
  if (contains_null_before && is_nullable) {
    add(program->null_class_id()->value());
    return true;
  }
  // TODO(kasper): Avoid re-computing the words per type here.
  return !is_empty(words_per_type(program));
}

bool TypeSet::remove_typecheck_interface(Program* program, int index, bool is_nullable) {
  bool contains_null_before = contains_null(program);
  int selector_offset = program->interface_check_offsets[index];
  // TODO(kasper): Avoid re-computing the words per type here.
  int words_per_type = TypeSet::words_per_type(program);
  Iterator it(*this, words_per_type);
  while (it.has_next()) {
    unsigned id = it.next();
    int entry_index = id + selector_offset;
    int entry_id = program->dispatch_table[entry_index];
    if (entry_id != -1) {
      Method target(program->bytecodes, entry_id);
      if (target.selector_offset() == selector_offset) continue;
    }
    remove(id);
  }
  if (contains_null_before && is_nullable) {
    add(program->null_class_id()->value());
    return true;
  }
  return !is_empty(words_per_type);
}

} // namespace toit::compiler
} // namespace toit

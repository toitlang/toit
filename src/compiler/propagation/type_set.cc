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
    for (int id = 0; id < program->class_bits.length(); id++) {
      if (!contains(id)) continue;
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
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (!contains(id)) continue;
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

int TypeSet::size(Program* program) const {
  if (is_block()) return 1;
  int size = 0;
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (contains(id)) size++;
  }
  return size;
}

bool TypeSet::is_empty(Program* program) const {
  if (is_block()) return false;
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (contains(id)) return false;
  }
  return true;
}

bool TypeSet::is_any(Program* program) const {
  if (is_block()) return false;
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (!contains(id)) return false;
  }
  return true;
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

void TypeSet::remove_range(unsigned start, unsigned end) {
  // TODO(kasper): We can make this much faster.
  for (unsigned type = start; type < end; type++) {
    remove(type);
  }
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
  return !is_empty(program);
}

bool TypeSet::remove_typecheck_interface(Program* program, int index, bool is_nullable) {
  bool contains_null_before = contains_null(program);
  // TODO(kasper): We can make this faster.
  int selector_offset = program->interface_check_offsets[index];
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (!contains(id)) continue;
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
  return !is_empty(program);
}

} // namespace toit::compiler
} // namespace toit

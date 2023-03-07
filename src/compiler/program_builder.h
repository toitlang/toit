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
#include <string>

#include "../top.h"
#include "../objects.h"
#include "../program_heap.h"

#include "list.h"
#include "map.h"
#include "symbol.h"
#include "util.h"

namespace toit {
namespace compiler {

// The builder class is used for installing and manipulating the program.
// A simple stack avoids the need for handles to survive garbage collection.
class ProgramBuilder {
 public:
  explicit ProgramBuilder(Program* program);

  Program* program() const { return program_; }
  int size() const { return stack_.size(); }

  void drop() { pop(); }
  void dup();

  // All push operations returns an index where the value is kept on the reflective stack.
  void push_null();
  void push_boolean(bool value);
  void push_smi(int64 value);
  void push_double(double value);
  void push_large_integer(int64 value);
  void push_string(const char* str);
  void push_string(const char* str, int length);
  void push_lazy_initializer_id(int id);

  // literal operations to add a literal and return the index of where it is kept in the global literal array.
  int add_double(double value);
  int add_integer(int64 value);
  int add_string(const char* str);
  int add_string(const char* str, int length);
  int add_byte_array(List<uint8> data);

  // peeks the top of the stack and adds it to global literal array.
  int add_to_literals();

  // Removes the top 'len' elements and replaces them with an array containing those elements.
  void create_class(int id, const char* name, int instance_size, bool is_runtime);
  int create_method(int selector_offset, bool is_field_stub, int arity, List<uint8> codes, int max_height);
  int create_lambda(int captured_count, int arity, List<uint8> codes, int max_height);
  int create_block(int arity, List<uint8> codes, int max_height);
  int absolute_bci_for(int method_id);
  void patch_uint32_at(int absolute_bci, uint32 value);

  void create_class_bits_table(int size);
  void create_dispatch_table(int size);
  void create_global_variables(int count);
  void create_literals();

  void set_dispatch_table_entry(int index, int id);
  void set_class_check_ids(const List<uint16>& class_check_ids);
  void set_interface_check_offsets(const List<uint16>& interface_check_offsets);

  void set_up_skeleton_program();

  // Prepare this program heap for execution.
  Program* cook();

#ifdef TOIT_DEBUG
  void print();
  void print_tos();
#endif

  // Returns the number of bytes allocated in the program space.
  int payload_size();

  void set_entry_point_index(int entry_point_index, int dispatch_index) {
    program_->_set_entry_point_index(entry_point_index, dispatch_index);
  }

  void set_invoke_bytecode_offset(Opcode opcode, int offset) {
    program_->set_invoke_bytecode_offset(opcode, offset);
  }

 private:
  void allocate_method(int bytecode_size, int max_height, int* method_id, Method* method);

  void set_builtin_class_id(const char* name, int id);

  void set_built_in_class_tags_and_sizes();
  void set_built_in_class_tag_and_size(Symbol name, TypeTag tag=TypeTag::INSTANCE_TAG, int size=-1) {
    built_in_class_tags_[std::string(name.c_str())] = tag;
    if (size != -1) {
      built_in_class_sizes_[std::string(name.c_str())] = size;
    }
  }
  String* lookup_symbol(const char* str);
  String* lookup_symbol(const char* str, int length);

  ProgramHeap program_heap_;
  Program* program_;

  UnorderedMap<std::string, String*> symbols_;
  std::vector<Object*> stack_;

  Map<std::string, int> string_literals_; // index of strings in literal vector.
  Map<std::string, int> byte_array_literals_; // index of strings in literal vector.
  Map<int64, int> integer_interals_; // index of int64 in literal vector.
  Map<uint64, int> double_literals_; // index of doubles in literal vector.
  // Class tags for built-in classes.
  // A built-in class must be present in the map to be counted as builtin.
  Map<std::string, TypeTag> built_in_class_tags_;
  // Class size for built-in classes.
  // If the class is not present, then the computed size (from the compiler) is used.
  Map<std::string, int> built_in_class_sizes_;
  std::vector<Object*> literals_;

  std::vector<uint8> all_bytecodes_;

  // Basic stack operations.
  Object* top();
  void push(Object* value);
  Object* pop();
};

} // namespace toit::compiler
} // namespace toit

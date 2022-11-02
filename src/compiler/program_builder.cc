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

#include "program_builder.h"
#include "token.h"
#include "tree_roots.h"
#include "../flags.h"
#include "../objects_inline.h"
#include "../printing.h"
#include "../process.h"
#include "../interpreter.h"
#include "../utils.h"

namespace toit {
namespace compiler {

ProgramBuilder::ProgramBuilder(Program* program)
    : program_heap_(program)
    , program_(program) {}

void ProgramBuilder::dup() {
  push(top());
}

void ProgramBuilder::push_null() {
  push(program_->null_object());
}

void ProgramBuilder::push_boolean(bool value) {
  push(value ? program_->true_object() : program_->false_object());
}

void ProgramBuilder::push_smi(int64 value) {
  push(Smi::from(value));
}

int ProgramBuilder::add_double(double value) {
  // Use bits to lookup double constants. Otherwise we would need to
  // special case NaN and -0.0.
  uint64 bits = bit_cast<uint64>(value);
  auto probe = double_literals_.find(bits);
  if (probe != double_literals_.end()) return probe->second;
  Double* object = program_heap_.allocate_double(value);
  auto idx = literals_.size();
  literals_.push_back(object);
  double_literals_[bits] = idx;
  return idx;
}

int ProgramBuilder::add_integer(int64 value) {
  auto probe = integer_interals_.find(value);
  if (probe != integer_interals_.end()) return probe->second;
  Object* object;
  if (Smi::is_valid(value)) {
    object = Smi::from(value);
  } else {
    object = program_heap_.allocate_large_integer(value);
  }
  auto idx = literals_.size();
  literals_.push_back(object);
  integer_interals_[value] = idx;
  return idx;
}

int ProgramBuilder::add_byte_array(List<uint8> data) {
  auto length = data.length();
  // Avoid assert for zero length
  std::string key(length == 0 ? "" : char_cast(&data[0]), length);
  auto probe = byte_array_literals_.find(key);
  if (probe != byte_array_literals_.end()) return probe->second;
  ByteArray* byte_array = program_heap_.allocate_byte_array(data.data(), length);
  auto idx = literals_.size();
  literals_.push_back(byte_array);
  byte_array_literals_[key] = idx;
  return idx;
}

int ProgramBuilder::add_string(const char* str) {
  return add_string(str, strlen(str));
}

int ProgramBuilder::add_string(const char* str, int length) {
  std::string key(str, length);
  auto probe = string_literals_.find(key);
  if (probe != string_literals_.end()) return probe->second;
  String* object = lookup_symbol(str, length);
  auto idx = literals_.size();
  literals_.push_back(object);
  string_literals_[key] = idx;
  return idx;
}

int ProgramBuilder::add_to_literals() {
  Object* object = pop();
  auto idx = literals_.size();
  literals_.push_back(object);
  return idx;
}

void ProgramBuilder::push_double(double value) {
  Double* object = program_heap_.allocate_double(value);
  push(object);
}

void ProgramBuilder::push_large_integer(int64 value) {
  ASSERT(!Smi::is_valid(value));
  LargeInteger* object = program_heap_.allocate_large_integer(value);
  push(object);
}

void ProgramBuilder::push_string(const char* str, int length) {
  String* string = lookup_symbol(str, length);
  push(string);
}

void ProgramBuilder::push_string(const char* str) {
  push_string(str, strlen(str));
}

void ProgramBuilder::push_lazy_initializer_id(int id) {
  Instance* lazy_initializer = program_heap_.allocate_instance(program_->lazy_initializer_class_id());
  lazy_initializer->at_put(0, Smi::from(id));
  push(lazy_initializer);
}

int ProgramBuilder::create_method(int selector_offset,
                                  bool is_field_accessor,
                                  int arity,
                                  List<uint8> bytecodes,
                                  int max_height) {
  int method_id;
  auto method = Method::invalid();
  allocate_method(bytecodes.length(), max_height, &method_id, &method);
  method._initialize_method(selector_offset, is_field_accessor, arity, bytecodes, max_height);
  return method_id;
}

int ProgramBuilder::create_lambda(int captured_count, int arity, List<uint8> bytecodes, int max_height) {
  int method_id;
  auto method = Method::invalid();
  allocate_method(bytecodes.length(), max_height, &method_id, &method);
  method._initialize_lambda(captured_count, arity, bytecodes, max_height);
  return method_id;
}

int ProgramBuilder::create_block(int arity, List<uint8> bytecodes, int max_height) {
  int method_id;
  auto method = Method::invalid();
  allocate_method(bytecodes.length(), max_height, &method_id, &method);
  method._initialize_block(arity, bytecodes, max_height);
  return method_id;
}

int ProgramBuilder::absolute_bci_for(int method_id) {
  Method method(&all_bytecodes_[method_id]);
  return method.bcp_from_bci(0) - &all_bytecodes_[0];
}

void ProgramBuilder::patch_uint32_at(int absolute_bci, uint32 value) {
  all_bytecodes_[absolute_bci + 0] = (value >>  0) & 0xff;
  all_bytecodes_[absolute_bci + 1] = (value >>  8) & 0xff;
  all_bytecodes_[absolute_bci + 2] = (value >> 16) & 0xff;
  all_bytecodes_[absolute_bci + 3] = (value >> 24) & 0xff;
}

void ProgramBuilder::create_class(int id, const char* name, int instance_size, bool is_runtime) {
  // Lazily initialize class tags and sizes.
  set_built_in_class_tags_and_sizes();
  // Only classes from the core-runtime can be builtin classes.
  uint16 class_bits;
  auto probe = built_in_class_tags_.find(name);
  if (is_runtime && probe != built_in_class_tags_.end()) {
    set_builtin_class_id(name, id);
    auto tag = probe->second;
    auto size_probe = built_in_class_sizes_.find(name);
    if (size_probe != built_in_class_sizes_.end()) {
      instance_size = size_probe->second;
    }
    class_bits = Program::compute_class_bits(tag, instance_size);
  } else {
    class_bits = Program::compute_class_bits(TypeTag::INSTANCE_TAG, instance_size);
  }
  program_->class_bits[id] = class_bits;
}

void ProgramBuilder::create_class_bits_table(int size) {
  auto class_bits = ListBuilder<uint16>::allocate(size);
  for (int i = 0; i < class_bits.length(); i++) {
    class_bits[i] = -1;
  }
  program_->set_class_bits_table(class_bits);
}

void ProgramBuilder::create_literals() {
  program_->literals.create(literals_.size());
  for (int index = 0; index < program_->literals.length(); index++) {
    program_->literals.at_put(index, literals_[index]);
  }
}

void ProgramBuilder::create_global_variables(int count) {
  program_->global_variables.create(count);
  for (int i = count - 1; i >= 0; i--) {
    program_->global_variables.at_put(i, pop());
  }
}

void ProgramBuilder::create_dispatch_table(int size) {
  auto dispatch_table = ListBuilder<int>::allocate(size);
  for (int i = 0; i < dispatch_table.length(); i++) {
    dispatch_table[i] = -1;
  }
  program_->set_dispatch_table(dispatch_table);
}

void ProgramBuilder::set_dispatch_table_entry(int index, int id) {
  program_->dispatch_table[index] = id;
}

void ProgramBuilder::allocate_method(int bytecode_size, int max_height, int* method_id, Method* method) {
  int allocation_size = Method::allocation_size(bytecode_size, max_height);
  *method_id = all_bytecodes_.size();
  all_bytecodes_.resize(all_bytecodes_.size() + allocation_size);
  Method result(&all_bytecodes_[*method_id]);
  *method = result;
}

void ProgramBuilder::set_built_in_class_tags_and_sizes() {
  if (!built_in_class_sizes_.empty()) return;

  // Set builtin class bits.
  set_built_in_class_tag_and_size(Symbols::Null_, TypeTag::ODDBALL_TAG);
  set_built_in_class_tag_and_size(Symbols::String_, TypeTag::STRING_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::SmallArray_, TypeTag::ARRAY_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::ByteArray_, TypeTag::BYTE_ARRAY_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::CowByteArray_);
  set_built_in_class_tag_and_size(Symbols::ByteArraySlice_);
  set_built_in_class_tag_and_size(Symbols::StringSlice_);
  set_built_in_class_tag_and_size(Symbols::List_);
  set_built_in_class_tag_and_size(Symbols::ListSlice_);
  set_built_in_class_tag_and_size(Symbols::Tombstone_);
  set_built_in_class_tag_and_size(Symbols::Map);
  set_built_in_class_tag_and_size(Symbols::Stack_, TypeTag::STACK_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::Object);
  set_built_in_class_tag_and_size(Symbols::True_, TypeTag::ODDBALL_TAG);
  set_built_in_class_tag_and_size(Symbols::False_, TypeTag::ODDBALL_TAG);
  set_built_in_class_tag_and_size(Symbols::SmallInteger_, TypeTag::INSTANCE_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::float_, TypeTag::DOUBLE_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::LargeInteger_, TypeTag::LARGE_INTEGER_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::LazyInitializer_);
  set_built_in_class_tag_and_size(Symbols::Task_, TypeTag::TASK_TAG);
  set_built_in_class_tag_and_size(Symbols::LargeArray_);
  set_built_in_class_tag_and_size(Symbols::Exception_);
}

void ProgramBuilder::set_up_skeleton_program() {
  int minimal_object_size = Instance::allocation_size(0);

  program_->set_null_object(static_cast<Instance*>(program_heap_._allocate_raw(minimal_object_size)));
  program_->null_object()->_set_header(program_, program_->null_class_id());
  program_->set_true_object(program_heap_.allocate_instance(program_->true_class_id()));
  program_->set_false_object(program_heap_.allocate_instance(program_->false_class_id()));

  // Allocate empty structures.
  program_->set_empty_array(program_heap_.allocate_array(0, program_->null_object()));

  // Pre-allocate the out of memory error.
  Instance* out_of_memory_error = program_heap_.allocate_instance(program_->exception_class_id());
  out_of_memory_error->at_put_no_write_barrier(0, lookup_symbol("OUT_OF_MEMORY"));
  out_of_memory_error->at_put_no_write_barrier(1, program_->null_object());  // Empty stack trace.
  program_->set_out_of_memory_error(out_of_memory_error);

  // Bind default literals.
  literals_.push_back(program_->true_object());
  literals_.push_back(program_->false_object());

  // Predefined symbols used for primitive failures.
  program_->set_allocation_failed(lookup_symbol("ALLOCATION_FAILED"));
  program_->set_already_closed(lookup_symbol("ALREADY_CLOSED"));
  program_->set_allocation_size_exceeded(lookup_symbol("ALLOCATION_SIZE_EXCEEDED"));
  program_->set_already_exists(lookup_symbol("ALREADY_EXISTS"));
  program_->set_division_by_zero(lookup_symbol("DIVISION_BY_ZERO"));
  program_->set_error(lookup_symbol("ERROR"));
  program_->set_file_not_found(lookup_symbol("FILE_NOT_FOUND"));
  program_->set_hardware_error(lookup_symbol("HARDWARE_ERROR"));
  program_->set_illegal_utf_8(lookup_symbol("ILLEGAL_UTF_8"));
  program_->set_invalid_argument(lookup_symbol("INVALID_ARGUMENT"));
  program_->set_malloc_failed(lookup_symbol("MALLOC_FAILED"));
  program_->set_cross_process_gc(lookup_symbol("CROSS_PROCESS_GC"));
  program_->set_negative_argument(lookup_symbol("NEGATIVE_ARGUMENT"));
  program_->set_out_of_bounds(lookup_symbol("OUT_OF_BOUNDS"));
  program_->set_out_of_range(lookup_symbol("OUT_OF_RANGE"));
  program_->set_already_in_use(lookup_symbol("ALREADY_IN_USE"));
  program_->set_overflow(lookup_symbol("OVERFLOW"));
  program_->set_privileged_primitive(lookup_symbol("PRIVILEGED_PRIMITIVE"));
  program_->set_permission_denied(lookup_symbol("PERMISSION_DENIED"));
  program_->set_quota_exceeded(lookup_symbol("QUOTA_EXCEEDED"));
  program_->set_read_failed(lookup_symbol("READ_FAILED"));
  program_->set_stack_overflow(lookup_symbol("STACK_OVERFLOW"));
  program_->set_unimplemented(lookup_symbol("UNIMPLEMENTED"));
  program_->set_wrong_object_type(lookup_symbol("WRONG_OBJECT_TYPE"));
  program_->set_app_sdk_version(lookup_symbol(vm_git_version()));
  program_->set_app_sdk_info(lookup_symbol(vm_git_info()));
}

void ProgramBuilder::set_source_mapping(const char* data) {
  int length = strlen(data);
  String* string = lookup_symbol(data, length);
  program_->set_source_mapping(string);
}

void ProgramBuilder::set_class_check_ids(const List<uint16>& class_check_ids) {
  program_->set_class_check_ids(class_check_ids);
}

void ProgramBuilder::set_interface_check_offsets(const List<uint16>& interface_check_offsets) {
  program_->set_interface_check_offsets(interface_check_offsets);
}

Program* ProgramBuilder::cook() {
  create_literals();
  program_->set_bytecodes(ListBuilder<uint8>::build_from_vector(all_bytecodes_));

  // Clear the symbol table not used during execution.
  symbols_.clear();
  program_heap_.migrate_to(program_);
  return program_;
}

void ProgramBuilder::set_builtin_class_id(const char* name, int id) {
  // TODO(florian): This is a really ugly implementation.
#define T(p, n) if (strcmp((Symbols:: n).c_str(), name) == 0) program_->set_##p##_class_id(Smi::from(id));
TREE_ROOT_CLASSES(T)
#undef T
  return;
}

String* ProgramBuilder::lookup_symbol(const char* str) {
  return lookup_symbol(str, strlen(str));
}

String* ProgramBuilder::lookup_symbol(const char* str, int length) {
  std::string key(str, length);
  String* string = symbols_.lookup(key);
  if (string != null) return string;
  string = program_heap_.allocate_string(str, length);
  symbols_[key] = string;
  return string;
}

void ProgramBuilder::push(Object* value) {
  stack_.push_back(value);
}

Object* ProgramBuilder::pop() {
  ASSERT(!stack_.empty());
  Object* result = stack_.back();
  stack_.pop_back();
  return result;
}

Object* ProgramBuilder::top() {
  ASSERT(!stack_.empty());
  return stack_.back();
}

#ifdef TOIT_DEBUG

void ProgramBuilder::print() {
  ConsolePrinter printer(program());
  printer.printf("Reflection stack %d:\n", size());
  for (int index = size() - 1; index >= 0; index--) {
    printer.printf("  %d: ", size() - index - 1);
    print_object_short(&printer, stack_[index]);
    printer.printf("\n");
  }
}

void ProgramBuilder::print_tos() {
  ConsolePrinter printer(program());
  print_object(&printer, top());
}

#endif

} // namespace toit::compiler
} // namespace toit

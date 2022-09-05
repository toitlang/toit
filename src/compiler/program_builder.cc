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
    : _program_heap(program)
    , _program(program) {}

void ProgramBuilder::dup() {
  push(top());
}

void ProgramBuilder::push_null() {
  push(_program->null_object());
}

void ProgramBuilder::push_boolean(bool value) {
  push(value ? _program->true_object() : _program->false_object());
}

void ProgramBuilder::push_smi(int64 value) {
  push(Smi::from(value));
}

int ProgramBuilder::add_double(double value) {
  // Use bits to lookup double constants. Otherwise we would need to
  // special case NaN and -0.0.
  uint64 bits = bit_cast<uint64>(value);
  auto probe = _double_literals.find(bits);
  if (probe != _double_literals.end()) return probe->second;
  Double* object = _program_heap.allocate_double(value);
  auto idx = _literals.size();
  _literals.push_back(object);
  _double_literals[bits] = idx;
  return idx;
}

int ProgramBuilder::add_integer(int64 value) {
  auto probe = _integer_interals.find(value);
  if (probe != _integer_interals.end()) return probe->second;
  Object* object;
  if (Smi::is_valid(value)) {
    object = Smi::from(value);
  } else {
    object = _program_heap.allocate_large_integer(value);
  }
  auto idx = _literals.size();
  _literals.push_back(object);
  _integer_interals[value] = idx;
  return idx;
}

int ProgramBuilder::add_byte_array(List<uint8> data) {
  auto length = data.length();
  // Avoid assert for zero length
  std::string key(length == 0 ? "" : char_cast(&data[0]), length);
  auto probe = _byte_array_literals.find(key);
  if (probe != _byte_array_literals.end()) return probe->second;
  ByteArray* byte_array = _program_heap.allocate_byte_array(data.data(), length);
  auto idx = _literals.size();
  _literals.push_back(byte_array);
  _byte_array_literals[key] = idx;
  return idx;
}

int ProgramBuilder::add_string(const char* str) {
  return add_string(str, strlen(str));
}

int ProgramBuilder::add_string(const char* str, int length) {
  std::string key(str, length);
  auto probe = _string_literals.find(key);
  if (probe != _string_literals.end()) return probe->second;
  String* object = lookup_symbol(str, length);
  auto idx = _literals.size();
  _literals.push_back(object);
  _string_literals[key] = idx;
  return idx;
}

int ProgramBuilder::add_to_literals() {
  Object* object = pop();
  auto idx = _literals.size();
  _literals.push_back(object);
  return idx;
}

void ProgramBuilder::push_double(double value) {
  Double* object = _program_heap.allocate_double(value);
  push(object);
}

void ProgramBuilder::push_large_integer(int64 value) {
  ASSERT(!Smi::is_valid(value));
  LargeInteger* object = _program_heap.allocate_large_integer(value);
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
  Instance* lazy_initializer = _program_heap.allocate_instance(_program->lazy_initializer_class_id());
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
  Method method(&_all_bytecodes[method_id]);
  return method.bcp_from_bci(0) - &_all_bytecodes[0];
}

void ProgramBuilder::patch_uint32_at(int absolute_bci, uint32 value) {
  _all_bytecodes[absolute_bci + 0] = (value >>  0) & 0xff;
  _all_bytecodes[absolute_bci + 1] = (value >>  8) & 0xff;
  _all_bytecodes[absolute_bci + 2] = (value >> 16) & 0xff;
  _all_bytecodes[absolute_bci + 3] = (value >> 24) & 0xff;
}

void ProgramBuilder::create_class(int id, const char* name, int instance_size, bool is_runtime) {
  // Lazily initialize class tags and sizes.
  set_built_in_class_tags_and_sizes();
  // Only classes from the core-runtime can be builtin classes.
  uint16 class_bits;
  auto probe = _built_in_class_tags.find(name);
  if (is_runtime && probe != _built_in_class_tags.end()) {
    set_builtin_class_id(name, id);
    auto tag = probe->second;
    auto size_probe = _built_in_class_sizes.find(name);
    if (size_probe != _built_in_class_sizes.end()) {
      instance_size = size_probe->second;
    }
    class_bits = Program::compute_class_bits(tag, instance_size);
  } else {
    class_bits = Program::compute_class_bits(TypeTag::INSTANCE_TAG, instance_size);
  }
  _program->class_bits[id] = class_bits;
}

void ProgramBuilder::create_class_bits_table(int size) {
  auto class_bits = ListBuilder<uint16>::allocate(size);
  for (int i = 0; i < class_bits.length(); i++) {
    class_bits[i] = -1;
  }
  _program->set_class_bits_table(class_bits);
}

void ProgramBuilder::create_literals() {
  _program->literals.create(_literals.size());
  for (int index = 0; index < _program->literals.length(); index++) {
    _program->literals.at_put(index, _literals[index]);
  }
}

void ProgramBuilder::create_global_variables(int count) {
  _program->global_variables.create(count);
  for (int i = count - 1; i >= 0; i--) {
    _program->global_variables.at_put(i, pop());
  }
}

void ProgramBuilder::create_dispatch_table(int size) {
  auto dispatch_table = ListBuilder<int>::allocate(size);
  for (int i = 0; i < dispatch_table.length(); i++) {
    dispatch_table[i] = -1;
  }
  _program->set_dispatch_table(dispatch_table);
}

void ProgramBuilder::set_dispatch_table_entry(int index, int id) {
  _program->dispatch_table[index] = id;
}

void ProgramBuilder::allocate_method(int bytecode_size, int max_height, int* method_id, Method* method) {
  int allocation_size = Method::allocation_size(bytecode_size, max_height);
  *method_id = _all_bytecodes.size();
  _all_bytecodes.resize(_all_bytecodes.size() + allocation_size);
  Method result(&_all_bytecodes[*method_id]);
  *method = result;
}

void ProgramBuilder::set_built_in_class_tags_and_sizes() {
  if (!_built_in_class_sizes.empty()) return;

  // Set builtin class bits.
  set_built_in_class_tag_and_size(Symbols::Null_, TypeTag::ODDBALL_TAG);
  set_built_in_class_tag_and_size(Symbols::String_, TypeTag::STRING_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::SmallArray_, TypeTag::ARRAY_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::ByteArray_, TypeTag::BYTE_ARRAY_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::CowByteArray_);
  set_built_in_class_tag_and_size(Symbols::ByteArraySlice_);
  set_built_in_class_tag_and_size(Symbols::StringSlice_);
  set_built_in_class_tag_and_size(Symbols::List_);
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

  _program->set_null_object(static_cast<Instance*>(_program_heap._allocate_raw(minimal_object_size)));
  _program->null_object()->_set_header(_program, _program->null_class_id());
  _program->set_true_object(_program_heap.allocate_instance(_program->true_class_id()));
  _program->set_false_object(_program_heap.allocate_instance(_program->false_class_id()));

  // Allocate empty structures.
  _program->set_empty_array(_program_heap.allocate_array(0, _program->null_object()));

  // Pre-allocate the out of memory error.
  Instance* out_of_memory_error = _program_heap.allocate_instance(_program->exception_class_id());
  out_of_memory_error->at_put_no_write_barrier(0, lookup_symbol("OUT_OF_MEMORY"));
  out_of_memory_error->at_put_no_write_barrier(1, _program->null_object());  // Empty stack trace.
  _program->set_out_of_memory_error(out_of_memory_error);

  // Bind default literals.
  _literals.push_back(_program->true_object());
  _literals.push_back(_program->false_object());

  // Predefined symbols used for primitive failures.
  _program->set_allocation_failed(lookup_symbol("ALLOCATION_FAILED"));
  _program->set_already_closed(lookup_symbol("ALREADY_CLOSED"));
  _program->set_allocation_size_exceeded(lookup_symbol("ALLOCATION_SIZE_EXCEEDED"));
  _program->set_already_exists(lookup_symbol("ALREADY_EXISTS"));
  _program->set_division_by_zero(lookup_symbol("DIVISION_BY_ZERO"));
  _program->set_error(lookup_symbol("ERROR"));
  _program->set_file_not_found(lookup_symbol("FILE_NOT_FOUND"));
  _program->set_hardware_error(lookup_symbol("HARDWARE_ERROR"));
  _program->set_illegal_utf_8(lookup_symbol("ILLEGAL_UTF_8"));
  _program->set_invalid_argument(lookup_symbol("INVALID_ARGUMENT"));
  _program->set_malloc_failed(lookup_symbol("MALLOC_FAILED"));
  _program->set_cross_process_gc(lookup_symbol("CROSS_PROCESS_GC"));
  _program->set_negative_argument(lookup_symbol("NEGATIVE_ARGUMENT"));
  _program->set_out_of_bounds(lookup_symbol("OUT_OF_BOUNDS"));
  _program->set_out_of_range(lookup_symbol("OUT_OF_RANGE"));
  _program->set_already_in_use(lookup_symbol("ALREADY_IN_USE"));
  _program->set_overflow(lookup_symbol("OVERFLOW"));
  _program->set_privileged_primitive(lookup_symbol("PRIVILEGED_PRIMITIVE"));
  _program->set_permission_denied(lookup_symbol("PERMISSION_DENIED"));
  _program->set_quota_exceeded(lookup_symbol("QUOTA_EXCEEDED"));
  _program->set_read_failed(lookup_symbol("READ_FAILED"));
  _program->set_stack_overflow(lookup_symbol("STACK_OVERFLOW"));
  _program->set_unimplemented(lookup_symbol("UNIMPLEMENTED"));
  _program->set_wrong_object_type(lookup_symbol("WRONG_OBJECT_TYPE"));
  _program->set_app_sdk_version(lookup_symbol(vm_git_version()));
  _program->set_app_sdk_info(lookup_symbol(vm_git_info()));
}

void ProgramBuilder::set_source_mapping(const char* data) {
  int length = strlen(data);
  String* string = lookup_symbol(data, length);
  _program->set_source_mapping(string);
}

void ProgramBuilder::set_class_check_ids(const List<uint16>& class_check_ids) {
  _program->set_class_check_ids(class_check_ids);
}

void ProgramBuilder::set_interface_check_offsets(const List<uint16>& interface_check_offsets) {
  _program->set_interface_check_offsets(interface_check_offsets);
}

Program* ProgramBuilder::cook() {
  create_literals();
  _program->set_bytecodes(ListBuilder<uint8>::build_from_vector(_all_bytecodes));

  // Clear the symbol table not used during execution.
  _symbols.clear();
  _program_heap.migrate_to(_program);
  return _program;
}

void ProgramBuilder::set_builtin_class_id(const char* name, int id) {
  // TODO(florian): This is a really ugly implementation.
#define T(p, n) if (strcmp((Symbols:: n).c_str(), name) == 0) _program-> set_##p##_class_id(Smi::from(id));
TREE_ROOT_CLASSES(T)
#undef T
  return;
}

String* ProgramBuilder::lookup_symbol(const char* str) {
  return lookup_symbol(str, strlen(str));
}

String* ProgramBuilder::lookup_symbol(const char* str, int length) {
  std::string key(str, length);
  String* string = _symbols.lookup(key);
  if (string != null) return string;
  string = _program_heap.allocate_string(str, length);
  _symbols[key] = string;
  return string;
}

void ProgramBuilder::push(Object* value) {
  _stack.push_back(value);
}

Object* ProgramBuilder::pop() {
  ASSERT(!_stack.empty());
  Object* result = _stack.back();
  _stack.pop_back();
  return result;
}

Object* ProgramBuilder::top() {
  ASSERT(!_stack.empty());
  return _stack.back();
}

#ifdef TOIT_DEBUG

void ProgramBuilder::print() {
  ConsolePrinter printer(program());
  printer.printf("Reflection stack %d:\n", size());
  for (int index = size() - 1; index >= 0; index--) {
    printer.printf("  %d: ", size() - index - 1);
    print_object_short(&printer, _stack[index]);
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

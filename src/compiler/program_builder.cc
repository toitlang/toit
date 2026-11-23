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
#include "bytecode_format.h"
#include "token.h"
#include "tree_roots.h"
#include "../flags.h"
#include "../objects_inline.h"
#include "../printing.h"
#include "../process.h"
#include "../interpreter.h"
#include "../interpreter_v2.h"
#include "../utils.h"
#include <stdlib.h>

namespace toit {
namespace compiler {

static int current_bytecode_format = 1;

int bytecode_format() { return current_bytecode_format; }

bool v2_builtin_enabled(int builtin) {
  int mask = Flags::v2_builtins;
  const char* override = getenv("TOIT_V2_BUILTINS");
  if (override != null) mask = atoi(override);
  return (mask & builtin) != 0;
}

bool v2_unchecked_enabled() {
  // Code for untrusted containers never gets the trusted-only twins: the
  // verifier would reject the program at launch or install.
  if (Flags::untrusted) return false;
  const char* override = getenv("TOIT_V2_UNCHECKED");
  if (override != null) return atoi(override) != 0;
  return Flags::v2_unchecked;
}

#ifndef TOIT_DEFAULT_BYTECODE_FORMAT
#define TOIT_DEFAULT_BYTECODE_FORMAT 2
#endif

int requested_bytecode_format() {
  int format = Flags::bytecode_format;
  if (format == 0) {
    const char* override = getenv("TOIT_BYTECODE_FORMAT");
    if (override != null && override[0] != '\0') format = atoi(override);
  }
  if (format == 0) format = TOIT_DEFAULT_BYTECODE_FORMAT;
  if (format != 1 && format != 2) {
    FATAL("Unsupported bytecode format %d", format);
  }
  return format;
}

void set_bytecode_format(int format) {
  ASSERT(format == 1 || format == 2);
  current_bytecode_format = format;
}

ProgramBuilder::ProgramBuilder(
    Program* program,
    MethodSelectorOffsets* method_selector_offsets)
    : program_heap_(program)
    , program_(program)
    , method_selector_offsets_(method_selector_offsets) {}

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

int ProgramBuilder::create_method_v2(int kind,
                                     int arity,
                                     int max_height,
                                     int selector,
                                     int aux,
                                     ReceiverRange receiver,
                                     List<uint8> bytecodes) {
  if (all_bytecodes_.empty()) {
    for (int i = 0; i < V2_TAG_SIZE; i++) all_bytecodes_.push_back(V2_TAG[i]);
  }
  ASSERT(0 <= arity && arity < 0x100);
  ASSERT(0 <= selector && selector <= V2_NO_VALUE);
  ASSERT(0 <= aux && aux <= 0xffff);
  if (kind != V2_KIND_BLOCK && (all_bytecodes_.size() & 1) != 0) {
    // The entries of all but blocks are odd, so that the u16 fields at odd
    // distances before them are 2-byte aligned (format note 21): a header
    // has an odd size, so it starts at an even offset. The pad byte ends
    // the previous body (a body ends at the next header) and is never
    // executed.
    ASSERT(!v2_method_entries_.empty());
    all_bytecodes_.push_back(V2_PAD);
  }
  int offset = all_bytecodes_.size();
  int id = v2_method_offsets_.size();
  v2_method_offsets_.push_back(offset);
  // The header ends at the entry (format note 21): every field at a fixed
  // distance from the entry, then the kind byte.
  auto u16 = [&](int value) {
    ASSERT(0 <= value && value <= 0xffff);
    all_bytecodes_.push_back(value & 0xff);
    all_bytecodes_.push_back(value >> 8);
  };
  int kind_byte = kind;
  if (kind == V2_KIND_METHOD || kind == V2_KIND_FIELD_ACCESSOR) {
    int start = V2_NO_VALUE;
    int end = V2_NO_VALUE;
    if (receiver.is_valid()) {
      ASSERT(0 <= receiver.start && receiver.start < receiver.end && receiver.end < V2_NO_VALUE);
      start = receiver.start;
      end = receiver.end;
    }
    if (kind == V2_KIND_FIELD_ACCESSOR) {
      u16(aux);
      u16(end);
    } else if (start != V2_NO_VALUE && end > start + 1) {
      u16(end);
    } else {
      kind_byte |= V2_KIND_SINGLE;  // One class or none.
    }
    u16(start);
    u16(selector);
  } else {
    ASSERT(selector == V2_NO_VALUE && !receiver.is_valid());
    if (kind == V2_KIND_LAMBDA) {
      u16(aux);
    } else {
      ASSERT(aux == 0);
    }
  }
  all_bytecodes_.push_back(kind_byte);
  int entry = all_bytecodes_.size();
  if (entry >= V2_MAX_BYTECODES) FATAL("format-2 bytecodes too large");
  v2_method_entries_.push_back(entry);
  v2_method_records_.push_back((static_cast<uint32>(entry) << 8) | static_cast<uint32>(arity));
  int body = all_bytecodes_.size();
  for (int i = 0; i < bytecodes.length(); i++) all_bytecodes_.push_back(bytecodes[i]);
  if (v2_unchecked_enabled()) {
    // Format note 20: the field accesses become their unchecked twins (the
    // same operands; trusted programs only).
    for (int i = 0; i < bytecodes.length();) {
      int opcode = bytecodes[i];
      ASSERT(opcode < V2_OPCODE_COUNT);
      int twin = v2_twin_of(opcode);
      if (twin >= 0) all_bytecodes_[body + i] = twin;
      i += V2_OPCODE_LENGTHS[opcode];
    }
  }
  global_max_stack_height_ = Utils::max(global_max_stack_height_, max_height);
  return id;
}

int ProgramBuilder::source_id_for(int method_id) {
  if (is_format2()) return v2_method_offsets_[method_id];
  return method_id;
}

int ProgramBuilder::create_method(word selector_offset,
                                  bool is_field_accessor,
                                  int arity,
                                  List<uint8> bytecodes,
                                  int max_height,
                                  ReceiverRange receiver,
                                  int field_index) {
  if (is_format2()) {
    int kind = is_field_accessor ? V2_KIND_FIELD_ACCESSOR : V2_KIND_METHOD;
    int selector = selector_offset >= 0 ? selector_offset : V2_NO_VALUE;
    int aux = is_field_accessor ? field_index : 0;
    int id = create_method_v2(kind, arity, max_height, selector, aux, receiver, bytecodes);
    (*method_selector_offsets_)[source_id_for(id)] = selector_offset;
    return id;
  }
  int method_id;
  auto method = Method::invalid();
  allocate_method(bytecodes.length(), max_height, &method_id, &method);
  (*method_selector_offsets_)[method_id] = selector_offset;
  method._initialize_method(selector_offset, is_field_accessor, arity, bytecodes, max_height);
  global_max_stack_height_ = Utils::max(global_max_stack_height_, max_height);
  return method_id;
}

int ProgramBuilder::create_lambda(int captured_count, int arity, List<uint8> bytecodes, int max_height) {
  if (is_format2()) {
    return create_method_v2(V2_KIND_LAMBDA, arity, max_height, V2_NO_VALUE, captured_count,
                            ReceiverRange(), bytecodes);
  }
  int method_id;
  auto method = Method::invalid();
  allocate_method(bytecodes.length(), max_height, &method_id, &method);
  method._initialize_lambda(captured_count, arity, bytecodes, max_height);
  return method_id;
}

int ProgramBuilder::create_block(int arity, List<uint8> bytecodes, int max_height) {
  if (is_format2()) {
    return create_method_v2(V2_KIND_BLOCK, arity, max_height, V2_NO_VALUE, 0,
                            ReceiverRange(), bytecodes);
  }
  int method_id;
  auto method = Method::invalid();
  allocate_method(bytecodes.length(), max_height, &method_id, &method);
  method._initialize_block(arity, bytecodes, max_height);
  return method_id;
}

int ProgramBuilder::absolute_bci_for(int method_id) {
  if (is_format2()) return v2_method_entries_[method_id];
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
  set_built_in_class_tag_and_size(Symbols::StringByteSlice_);
  set_built_in_class_tag_and_size(Symbols::List_);
  set_built_in_class_tag_and_size(Symbols::ListSlice_);
  set_built_in_class_tag_and_size(Symbols::Tombstone_);
  set_built_in_class_tag_and_size(Symbols::Map);
  set_built_in_class_tag_and_size(Symbols::Stack_, TypeTag::STACK_TAG, 0);
  set_built_in_class_tag_and_size(Symbols::Object);
  set_built_in_class_tag_and_size(Symbols::True, TypeTag::ODDBALL_TAG);
  set_built_in_class_tag_and_size(Symbols::False, TypeTag::ODDBALL_TAG);
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
  if (is_format2()) {
    // The values of the exceptions the format-2 machine raises itself.
    #define ADD_FAILURE_STRING(name) add_string(#name);
    V2_FAILURE_STRINGS(ADD_FAILURE_STRING)
    #undef ADD_FAILURE_STRING
  }

  // Predefined symbols used for primitive failures.
  #define SET_ERROR_STRING(name, upper_name) \
    program_->set_##name(lookup_symbol(#upper_name));
  ERROR_STRINGS(SET_ERROR_STRING)
  #undef SET_ERROR_STRING

  program_->set_app_sdk_version(lookup_symbol(vm_git_version()));
  program_->set_app_sdk_info(lookup_symbol(vm_git_info()));
}

void ProgramBuilder::set_class_check_ids(const List<uint16>& class_check_ids) {
  program_->set_class_check_ids(class_check_ids);
}

void ProgramBuilder::set_interface_check_offsets(const List<uint16>& interface_check_offsets) {
  program_->set_interface_check_offsets(interface_check_offsets);
}

Program* ProgramBuilder::cook() {
  program_->set_bytecodes(ListBuilder<uint8>::build_from_vector(all_bytecodes_));
  if (is_format2()) {
    // The method table as the last literal (V2MethodTable::TABLE_LITERAL_MARKER,
    // format note 21): its records are the methods' entries and arities; a
    // device runs the program from flash without a table in RAM. The bytes
    // stay alive with the compiler (external byte arrays keep the pointer).
    word table_length = 0;
    uint8* table = V2MethodTable::encode_table_literal(v2_method_records_.data(), v2_method_records_.size(),
                                                       all_bytecodes_.size(), &table_length);
    if (table == null) FATAL("out of memory");
    add_byte_array(List<uint8>(table, table_length));
  }
  create_literals();
  program_->set_global_max_stack_height(global_max_stack_height_);

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

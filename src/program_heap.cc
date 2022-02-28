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

#include "program_heap.h"

#include "flags.h"
#include "heap_report.h"
#include "interpreter.h"
#include "os.h"
#include "primitive.h"
#include "printing.h"
#include "process.h"
#include "scheduler.h"
#include "utils.h"
#include "vm.h"

#include "objects_inline.h"

#ifdef TOIT_FREERTOS
#include "esp_heap_caps.h"
#endif

namespace toit {

ProgramHeap::ProgramHeap(Program* program, ProgramBlock* initial_block)
    : ProgramRawHeap()
    , _program(program)
    , _in_gc(false)
    , _gc_allowed(true)
    , _total_bytes_allocated(0)
    , _last_allocation_result(ALLOCATION_SUCCESS) {
  _blocks.append(initial_block);
}

ProgramHeap::~ProgramHeap() {
  set_writable(true);
  _blocks.free_blocks(this);
}

Instance* ProgramHeap::allocate_instance(Smi* class_id) {
  int size = program()->instance_size_for(class_id);
  TypeTag class_tag = program()->class_tag_for(class_id);
  return allocate_instance(class_tag, class_id, Smi::from(size));
}

Instance* ProgramHeap::allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size) {
  Instance* result = unvoid_cast<Instance*>(_allocate_raw(instance_size->value()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(class_id, class_tag);
  return result;
}

Array* ProgramHeap::allocate_array(int length, Object* filler) {
  ASSERT(length >= 0);
  ASSERT(length <= Array::max_length_in_program());
  HeapObject* result = _allocate_raw(Array::allocation_size(length));
  if (result == null) {
    return null;  // Allocation failure.
  }
  // Initialize object.
  result->_set_header(_program, _program->array_class_id());
  Array::cast(result)->_initialize(length, filler);
  return Array::cast(result);
}

Array* ProgramHeap::allocate_array(int length) {
  ASSERT(length >= 0);
  ASSERT(length <= Array::max_length_in_program());
  HeapObject* result = _allocate_raw(Array::allocation_size(length));
  if (result == null) {
    return null;  // Allocation failure.
  }
  // Initialize object.
  result->_set_header(_program, _program->array_class_id());
  Array::cast(result)->_initialize(length);
  return Array::cast(result);
}

ByteArray* ProgramHeap::allocate_internal_byte_array(int length) {
  ASSERT(length >= 0);
  // Byte array should fit within one heap block.
  ASSERT(length <= ByteArray::max_internal_size_in_program());
  ByteArray* result = unvoid_cast<ByteArray*>(_allocate_raw(ByteArray::internal_allocation_size(length)));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->byte_array_class_id());
  result->_initialize(length);
  return result;
}

Double* ProgramHeap::allocate_double(double value) {
  HeapObject* result = _allocate_raw(Double::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->double_class_id());
  Double::cast(result)->_initialize(value);
  return Double::cast(result);
}

LargeInteger* ProgramHeap::allocate_large_integer(int64 value) {
  HeapObject* result = _allocate_raw(LargeInteger::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->large_integer_class_id());
  LargeInteger::cast(result)->_initialize(value);
  return LargeInteger::cast(result);
}

int ProgramHeap::payload_size() {
  return _blocks.payload_size();
}

String* ProgramHeap::allocate_internal_string(int length) {
  ASSERT(length >= 0);
  ASSERT(length <= String::max_internal_size_in_program());
  HeapObject* result = _allocate_raw(String::internal_allocation_size(length));
  if (result == null) return null;
  // Initialize object.
  Smi* string_id = program()->string_class_id();
  result->_set_header(string_id, program()->class_tag_for(string_id));
  String::cast(result)->_set_length(length);
  String::cast(result)->_raw_set_hash_code(String::NO_HASH_CODE);
  String::Bytes bytes(String::cast(result));
  bytes._set_end();
  ASSERT(bytes.length() == length);
  return String::cast(result);
}

void ProgramHeap::migrate_to(Program* program) {
  set_writable(false);
  program->take_blocks(&_blocks);
}

HeapObject* ProgramHeap::_allocate_raw(int byte_size) {
  ASSERT(byte_size > 0);
  ASSERT(byte_size <= ProgramBlock::max_payload_size());
  HeapObject* result = _blocks.last()->allocate_raw(byte_size);
  if (result == null) {
    AllocationResult expand_result = _expand();
    set_last_allocation_result(expand_result);
    if (expand_result != ALLOCATION_SUCCESS) return null;
    result = _blocks.last()->allocate_raw(byte_size);
  }
  if (result == null) return null;
  _total_bytes_allocated += byte_size;
  return result;
}

ProgramHeap::AllocationResult ProgramHeap::_expand() {
  ProgramBlock* block = VM::current()->program_heap_memory()->allocate_block(this);
  if (block == null) return ALLOCATION_OUT_OF_MEMORY;
  _blocks.append(block);
  return ALLOCATION_SUCCESS;
}

String* ProgramHeap::allocate_string(const char* str) {
  return allocate_string(str, strlen(str));
}

String* ProgramHeap::allocate_string(const char* str, int length) {
  bool can_fit_in_heap_block = length <= String::max_internal_size_in_program();
  String* result;
  if (can_fit_in_heap_block) {
    result = allocate_internal_string(length);
    // We are in the program heap. We should never run out of memory.
    ASSERT(result != null);
    // Initialize object.
    String::Bytes bytes(result);
    bytes._initialize(str);
  } else {
    result = allocate_external_string(length, const_cast<uint8*>(unsigned_cast(str)));
  }
  result->hash_code();  // Ensure hash_code is computed at creation.
  return result;
}

ByteArray* ProgramHeap::allocate_byte_array(const uint8* data, int length) {
  if (length > ByteArray::max_internal_size_in_program()) {
    auto result = allocate_external_byte_array(length, const_cast<uint8*>(data));
    // We are on the program heap which should never run out of memory.
    ASSERT(result != null);
    return result;
  }
  auto byte_array = allocate_internal_byte_array(length);
  // We are on the program heap which should never run out of memory.
  ASSERT(byte_array != null);
  ByteArray::Bytes bytes(byte_array);
  if (length != 0) memcpy(bytes.address(), data, length);
  return byte_array;
}

ByteArray* ProgramHeap::allocate_external_byte_array(int length, uint8* memory) {
  ByteArray* result = unvoid_cast<ByteArray*>(_allocate_raw(ByteArray::external_allocation_size()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->byte_array_class_id());
  result->_initialize_external_memory(length, memory, false);
  return result;
}

String* ProgramHeap::allocate_external_string(int length, uint8* memory) {
  String* result = unvoid_cast<String*>(_allocate_raw(String::external_allocation_size()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program(), program()->string_class_id());
  result->_set_external_length(length);
  result->_raw_set_hash_code(String::NO_HASH_CODE);
  result->_set_external_address(memory);
  ASSERT(!result->content_on_heap());
  if (memory[length] != '\0') {
    // TODO(florian): we should not have '\0' at the end of strings anymore.
    String::Bytes bytes(String::cast(result));
    bytes._set_end();
  }
  return result;
}

// We initialize lazily - this is because the number of objects can grow during
// iteration.
ProgramHeap::Iterator::Iterator(ProgramBlockList& list, Program* program)
  : _list(list)
  , _iterator(list.end())  // Set to null.
  , _block(null)
  , _current(null)
  , _program(program) {}

bool ProgramHeap::Iterator::eos() {
  return _list.is_empty()
      || (_block == null
          ? _list.first()->is_empty()
          :  (_current >= _block->top() && _block == _list.last()));
}

void ProgramHeap::Iterator::ensure_started() {
  ASSERT(!eos());
  if (_block == null) {
     _iterator = _list.begin();
     _block = *_iterator;
     _current = _block->base();
  }
}

HeapObject* ProgramHeap::Iterator::current() {
  ensure_started();
  if (_current >= _block->top() && _block != _list.last()) {
    _block = *++_iterator;
    _current = _block->base();
  }
  ASSERT(!_block->is_empty());
  return HeapObject::cast(_current);
}

void ProgramHeap::Iterator::advance() {
  ensure_started();

  ASSERT(HeapObject::cast(_current)->header()->is_smi());  // Header is not a forwarding pointer.
  _current = Utils::address_at(_current, HeapObject::cast(_current)->size(_program));
  if (_current >= _block->top() && _block != _list.last()) {
    _block = *++_iterator;
    _current = _block->base();
    ASSERT(!_block->is_empty());
  }
}

}

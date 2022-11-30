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

#include "flags.h"
#include "objects.h"
#include "objects_inline.h"
#include "process.h"
#include "utils.h"

namespace toit {

bool Object::mutable_byte_content(Process* process, uint8** content, int* length, Error** error) {
  if (is_byte_array(this)) {
    auto byte_array = ByteArray::cast(this);
    // External byte arrays can have structs in them. This is captured in the external tag.
    // We only allow extracting the byte content from an external byte arrays iff it is tagged with RawByteType.
    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;
    ByteArray::Bytes bytes(byte_array);
    *length = bytes.length();
    *content = bytes.address();
    return true;
  }
  if (!is_instance(this)) return false;

  auto program = process->program();
  auto instance = Instance::cast(this);
  if (instance->class_id() == program->byte_array_cow_class_id()) {
    Object* backing = instance->at(Instance::BYTE_ARRAY_COW_BACKING_INDEX);
    auto is_mutable = instance->at(Instance::BYTE_ARRAY_COW_IS_MUTABLE_INDEX);
    if (is_mutable == process->program()->true_object()) {
      return backing->mutable_byte_content(process, content, length, error);
    }
    ASSERT(is_mutable == process->program()->false_object());

    const uint8* immutable_content;
    int immutable_length;
    if (!backing->byte_content(program, &immutable_content, &immutable_length, STRINGS_OR_BYTE_ARRAYS)) {
      return false;
    }

    Object* new_backing = process->allocate_byte_array(immutable_length, error);
    if (new_backing == null) {
      *content = null;
      *length = 0;
      // We return 'true' as this should have worked, but we might just have
      // run out of memory. The 'error' contains the reason things failed.
      return true;
    }

    ByteArray::Bytes bytes(ByteArray::cast(new_backing));
    memcpy(bytes.address(), immutable_content, immutable_length);

    instance->at_put(0, new_backing);
    instance->at_put(1, process->program()->true_object());
    return new_backing->mutable_byte_content(process, content, length, error);
  } else if (instance->class_id() == program->byte_array_slice_class_id()) {
    auto byte_array = instance->at(Instance::BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX);
    auto from = instance->at(Instance::BYTE_ARRAY_SLICE_FROM_INDEX);
    auto to = instance->at(Instance::BYTE_ARRAY_SLICE_TO_INDEX);
    if (!is_heap_object(byte_array)) return false;
    // TODO(florian): we could eventually accept larger integers here.
    if (!is_smi(from)) return false;
    if (!is_smi(to)) return false;
    int from_value = Smi::cast(from)->value();
    int to_value = Smi::cast(to)->value();
    bool inner_success = HeapObject::cast(byte_array)->mutable_byte_content(process, content, length, error);
    if (!inner_success) return false;
    // If the content is null, then we probably failed allocating the object.
    // Might work after a GC.
    if (content == null) return inner_success;
    if (0 <= from_value && from_value <= to_value && to_value <= *length) {
      *content += from_value;
      *length = to_value - from_value;
      return true;
    }
  }
  return false;
}

bool Object::mutable_byte_content(Process* process, MutableBlob* blob, Error** error) {
  uint8* content = null;
  int length = 0;
  auto result = mutable_byte_content(process, &content, &length, error);
  *blob = MutableBlob(content, length);
  return result;
}

uint8* ByteArray::neuter(Process* process) {
  ASSERT(has_external_address());
  ASSERT(external_tag() == RawByteTag);
  Bytes bytes(this);
  process->unregister_external_allocation(bytes.length());
  _set_external_address(null);
  _set_external_length(0);
  return bytes.address();
}

void ByteArray::resize_external(Process* process, word new_length) {
  ASSERT(has_external_address());
  ASSERT(external_tag() == RawByteTag);
  ASSERT(new_length <= _external_length());
  process->unregister_external_allocation(_external_length());
  process->register_external_allocation(new_length);
  _set_external_length(new_length);
  uint8* new_data = AllocationManager::reallocate(_external_address(), new_length);
  if (new_data != null) {
    // Realloc succeeded.
    _set_external_address(new_data);
  } else if (new_length == 0) {
    // Realloc was really just a free.
    _set_external_address(null);
  } else {
    // Realloc failed because we are very close to out-of-memory.  The malloc
    // implementation doesn't normally shrink small existing allocations,
    // lacking an implementation for that.  Instead it will allocate a new area
    // and copy the data there, an operation that can fail under memory
    // pressure.  In that rare case we leave the larger buffer attached to the
    // byte array, which can be a bit of a waste.
  }
}

void Stack::copy_to(Stack* other) {
  int used = length() - top();
  ASSERT(other->length() >= used);
  int displacement = other->length() - length();
  memcpy(other->_array_address(top() + displacement), _array_address(top()), used * WORD_SIZE);
  other->_set_top(displacement + top());
  other->_set_try_top(displacement + try_top());
  // We've updated the other stack without using the write barrier.
  // This is typically only done from within the interpreter, where
  // the other stack immediately becomes the current interpreter
  // stack through a call of other->transfer_to_interpreter(...). In
  // such cases, it isn't strictly necessary to insert the other
  // stack in the remembered set here, because it will always happen
  // before leaving the interpreter; also before garbage collections.
  // However, we play it safe and add it here because we have
  // written into the stack and it might point to new objects.
  GcMetadata::insert_into_remembered_set(other);
}

void Stack::transfer_to_interpreter(Interpreter* interpreter) {
  if (is_guard_zone_touched()) FATAL("stack overflow detected");
  ASSERT(top() >= 0);
  ASSERT(top() <= length());
  interpreter->limit_ = _stack_limit_addr();
  interpreter->base_ = _stack_base_addr();
  interpreter->sp_ = _stack_sp_addr();
  interpreter->try_sp_ = _stack_try_sp_addr();
  ASSERT(top() == (interpreter->sp_ - _stack_limit_addr()));
  _set_top(-1);
}

void Stack::transfer_from_interpreter(Interpreter* interpreter) {
  if (is_guard_zone_touched()) FATAL("stack overflow detected");
  ASSERT(top() == -1);
  _set_top(interpreter->sp_ - _stack_limit_addr());
  _set_try_top(interpreter->try_sp_ - _stack_limit_addr());
  ASSERT(top() >= 0);
  ASSERT(top() <= length());
  // The interpreter doesn't use the write barrier when pushing to the
  // stack, so we have to add it here. This is always done before
  // garbage collections, so any stack that has been used by the
  // interpreter since the last GC will be part of the remembered set.
  GcMetadata::insert_into_remembered_set(this);
}

bool HeapObject::in_remembered_set() {
  if (*GcMetadata::remembered_set_for(_raw()) == GcMetadata::NEW_SPACE_POINTERS) {
    return true;
  }
  return GcMetadata::get_page_type(this) == NEW_SPACE_PAGE;
}

}

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
#include "heap.h"
#include "heap_roots.h"
#include "objects.h"
#include "process.h"

namespace toit {

FinalizerNode::~FinalizerNode() {}

void ToitFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
  cb->do_root(reinterpret_cast<Object**>(&lambda_));
}

bool ToitFinalizerNode::has_key(HeapObject* key) {
  return key_ == key;
}

bool ToitFinalizerNode::alive(LivenessOracle* oracle) {
  return oracle->is_alive(key_);
}

bool ToitFinalizerNode::handle_not_alive(RootCallback* ss, ObjectHeap* heap) {
  if (!key_->has_active_finalizer()) {
    return true;  // Delete me, the object no longer needs a finalizer.
  }
  key_->clear_has_active_finalizer();
  // Clear the key so it is not retained.
  set_key(heap->program()->null_object());
  roots_do(ss);
  // Since the object is not alive, we queue the finalizer for execution.
  heap->queue_finalizer(this);
  return false;  // Don't delete me, I'm on the other queue now.
}

bool ToitFinalizerNode::has_active_finalizer(LivenessOracle* oracle) {
  return oracle->has_active_finalizer(key_);
}

VmFinalizerNode::~VmFinalizerNode() {}

void VmFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
}

bool VmFinalizerNode::has_key(HeapObject* key) {
  return key_ == key;
}

bool VmFinalizerNode::alive(LivenessOracle* oracle) {
  return oracle->is_alive(key_);
}

bool VmFinalizerNode::handle_not_alive(RootCallback* ss, ObjectHeap* heap) {
  if (!key_->has_active_finalizer()) return true;
  free_external_memory(heap->owner());
  return true;  // Delete me now.
}

bool VmFinalizerNode::has_active_finalizer(LivenessOracle* oracle) {
  return oracle->has_active_finalizer(key_);
}

void VmFinalizerNode::free_external_memory(Process* process) {
  uint8* memory = null;
  word accounting_size = 0;
  if (is_byte_array(key())) {
    ByteArray* byte_array = ByteArray::cast(key());
    if (byte_array->external_tag() == MappedFileTag) return;  // TODO(erik): release mapped file, so flash storage can be reclaimed.
    ASSERT(byte_array->has_external_address());
    ByteArray::Bytes bytes(byte_array);
    memory = bytes.address();
    accounting_size = bytes.length();
    // Accounting size is 0 if the byte array is tagged, since we don't account
    // memory for Resources etc.
    ASSERT(byte_array->external_tag() == RawByteTag || byte_array->external_tag() == NullStructTag);
  } else if (is_string(key())) {
    String* string = String::cast(key());
    memory = string->as_external();
    // Add one because the strings are allocated with a null termination byte.
    accounting_size = string->length() + 1;
  }
  if (memory != null) {
    if (Flags::allocation) printf("Deleting external memory for string %p\n", memory);
    free(memory);
    process->unregister_external_allocation(accounting_size);
  }
}

}  // namespace.

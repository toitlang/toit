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

void WeakMapFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
  cb->do_root(reinterpret_cast<Object**>(&lambda_));
}

// The WeakMapFinalizer has the problem that the backing collection (normally a
// list) may point at parts (arraylets) that have already been moved to the
// other new-space, leaving forwarding pointers in the headers.  We need to
// update those pointers before regular functions that work on arrays and lists
// can be used.
// Returns false if something unexpected happens.  In that case we fall back
// to a strong map without weak processing.
static bool update_forwarding_pointers(Process* process, RootCallback* cb, Object* backing, word size) {
  // Sometimes a deserialized map contains a backing that is an array, not a
  // list.
  Object* array_object = backing;
  if (!is_array(backing)) {
    if (!is_instance(backing)) {
      return false;  // Not a list or an array.
    }
  }
}

bool WeakMapFinalizerNode::process(bool in_closure_queue, RootCallback* cb, LivenessOracle* oracle) {
  if (!oracle->has_active_finalizer(key_) {
    delete this;
    return true;  // Unlink me, the object no longer needs a finalizer.
  }
  if (oracle->is_alive(key_)) {
    roots_do(cb);
    if (!cb->aggressive()) {
      // Everything was already handled.
      return false;  // Don't unlink me.
    }
    // We are in aggressive mode, so we need to zap values in the map that are
    // not reachable by other ways.
    bool has_zapped = false;
    // We already visited the roots, so the key is updated to the destination.
    Instance* map = Instance::cast(key_);
    // Update the pointer to the backing collection.
    cb->do_root(reinterpret_cast<Object**>(map->root_at(Instance::MAP_BACKING_INDEX)));
    Object* backing = map->at(Instance::MAP_BACKING_INDEX);
    word size = Smit::cast(map->at(Instance::MAP_SIZE_INDEX))->value();
    update_forwarding_pointers(process, backing, size);
    for (word i = 0; i < size; i += 2) {
      Object* key;
      bool ok = Interpreter::fast_at(process, backing, i, false, &key);
      ASSERT(ok);
      cb->do_root(reinterpret_cast<Object**>(&key));
      ok = Interpreter::fast_at(process, backing, i, true, &key);  // Put back the key.
      Object* value;
      ok = Interpreter::fast_at(process, backing, i + 1, false, &value);
      ASSERT(ok);
      if (oracle->is_alive(value)) {
        cb->do_root(reinterpret_cast<Object**>(&value));


    ...
    if (has_zapped) {
      if (in_closure_queue) {
        return false;  // Stay in the queue, processing is already scheduled.
      }
      heap_->queue_finalizer(this);
      return true;  // Unlink me, I'm in the other list now.
    }
    return false;  // Don't unlink me.
  }
  // The map is not reachable.  Zap all its content, and remove the weakness,
  // so that we can remove it from this list, even if it is revived (in that
  // case it has lost its weakness, but that's better than being marked weak
  // when it is not on the list, which would cause dangling pointers).
  key_->clear_has_active_finalizer();
  map->at_put(Instance::MAP_SIZE_INDEX, Smi::from(0));
  map->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
  map->at_put(Instance::MAP_INDEX_INDEX, program_->null_object());
  map->at_put(Instance::MAP_BACKING_INDEX, program_->null_object());
  delete this;
  return true;  // Unlink me.
}

void ToitFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
  cb->do_root(reinterpret_cast<Object**>(&lambda_));
}

bool ToitFinalizerNode::process(bool in_closure_queue, RootCallback* cb, LivenessOracle* oracle) {
  if (in_closure_queue) {
    roots_do(cb);
    return false;  // Don't unlink me.
  }
  if (!oracle->has_active_finalizer(key_) {
    delete this;
    return true;  // Unlink me, the object no longer needs a finalizer.
  }
  if (oracle->is_alive(key_)) {
    do_roots(cb);
    return false;  // Don't unlink me.
  }
  key_->clear_has_active_finalizer();
  // Clear the key so it is not retained.
  key_ = heap_->program()->null_object();
  cb->do_root(reinterpret_cast<Object**>(&lambda_));
  // Since the object is not alive, we queue the finalizer for execution.
  heap_->queue_finalizer(this);
  return true;  // Unlink me, I'm in the other list now.
}

VmFinalizerNode::~VmFinalizerNode() {}

void VmFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
}

bool VmFinalizerNode::process(Process* process, bool in_closure_queue, RootCallback* cb, LivenessOracle* oracle) {
  if (oracle->is_alive(key_)) {
    cb->do_root(reinterpret_cast<Object**>(&key_));
    return false;  // Don't unlink me.
  }
  free_external_memory(process);
  delete this;
  return true;  // Unlink me.
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

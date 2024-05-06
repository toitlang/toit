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
#include "objects_inline.h"
#include "process.h"

namespace toit {

FinalizerNode::~FinalizerNode() {}

void WeakMapFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
  cb->do_root(reinterpret_cast<Object**>(&lambda_));
}

static bool recursive_zap_dead_values(Program* program, Object* backing_array_object, LivenessOracle* oracle) {
  bool has_zapped = false;
  if (!is_heap_object(backing_array_object)) return false;  // Defensive.
  if (is_array(backing_array_object)) {
    Array* backing_array = Array::cast(backing_array_object);
    word size = backing_array->length();
    // The backing has the order key, value, key, value...
    // We only zap the values.
    for (word i = 1; i < size; i += 2) {
      Object* entry_object = backing_array->at(i);
      if (is_smi(entry_object)) continue;
      HeapObject* entry = HeapObject::cast(entry_object);
      if (entry->class_id() == program->tombstone_class_id()) continue;
      if (!oracle->is_alive(entry)) {
        backing_array->at_put(i, program->null_object());
        has_zapped = true;
      }
    }
  } else {
    Smi* class_id = HeapObject::cast(backing_array_object)->class_id();
    if (class_id != program->large_array_class_id()) return false;  // Defensive.
    Instance* instance = Instance::cast(backing_array_object);
    Object* vector_object = instance->at(Instance::LARGE_ARRAY_VECTOR_INDEX);
    if (!is_array(vector_object)) return false;  // Defensive.
    Array* vector = Array::cast(vector_object);
    word size = vector->length();
    for (word i = 0; i < size; i++) {
      bool arraylet_had_zaps = recursive_zap_dead_values(program, vector->at(i), oracle);
      if (arraylet_had_zaps) has_zapped = true;
    }
  }
  return has_zapped;
}

static bool zap_dead_values(Program* program, Instance* map, RootCallback* cb, LivenessOracle* oracle) {
  // If we ever allow weak map zapping on scavenges we will have to start
  // using roots_do on the objects that hold the backing (list, arrays, large
  // arrays) so that we get the new location of the collections we are zapping
  // entries in.  Mark-sweep-compact does not move objects until later, so we
  // don't currently need to worry about that.
  Object* backing_object = map->at(Instance::MAP_BACKING_INDEX);
  if (!is_instance(backing_object)) return false;
  Instance* backing_list = Instance::cast(backing_object);
  Smi* class_id = backing_list->class_id();
  if (class_id != program->list_class_id()) return false;
  Object *backing_array_object = backing_list->at(Instance::LIST_ARRAY_INDEX);
  bool has_zapped = recursive_zap_dead_values(program, backing_array_object, oracle);
  return has_zapped;
}

class MarkingShim : public RootCallback {
 public:
  MarkingShim(RootCallback* cb) : cb_(cb) {}
  virtual void do_roots(Object** roots, word length) {
    cb_->do_roots(roots, length);
  }
  virtual bool shrink_stacks() const { UNREACHABLE(); }
  virtual bool skip_marking(HeapObject* object) const {
    return false;  // Always mark.
  }

 private:
  RootCallback* cb_;
};

bool WeakMapFinalizerNode::weak_processing(bool in_closure_queue, RootCallback* cb, LivenessOracle* oracle) {
  if (!oracle->has_active_finalizer(key_)) {
    delete this;
    return true;  // Unlink me, the object no longer needs a finalizer.
  }
  Process* process = heap_->owner();
  Program* program = process->program();
  if (oracle->is_alive(key_)) {
    // In scavenges this will update this node's map pointer to the new location.
    roots_do(cb);
    if (!cb->skip_marking(map())) {
      // Not zapping weak pointers in this GC.
      return false;  // Don't unlink me.
    }
    // We are in map cleaning mode, so the normal marking or scavenging did not
    // necessarily process the backing.  We need to zap values in the map that
    // are not reachable by other ways.
    // We skipped the visiting of the map members during the initial marking
    // phase, otherwise the values would already be marked reachable.  But we
    // need to do that now, so that the backing and index are marked live.
    MarkingShim shim(cb);
    map()->roots_do(program, &shim);
    bool has_zapped = zap_dead_values(program, map(), cb, oracle);
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
  map()->clear_has_active_finalizer();
  map()->at_put(Instance::MAP_SIZE_INDEX, Smi::from(0));
  map()->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
  map()->at_put(Instance::MAP_INDEX_INDEX, process->null_object());
  map()->at_put(Instance::MAP_BACKING_INDEX, process->null_object());
  delete this;
  return true;  // Unlink me.
}

void ToitFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
  cb->do_root(reinterpret_cast<Object**>(&lambda_));
}

bool ToitFinalizerNode::weak_processing(bool in_closure_queue, RootCallback* cb, LivenessOracle* oracle) {
  if (in_closure_queue) {
    roots_do(cb);
    return false;  // Don't unlink me.
  }
  if (!oracle->has_active_finalizer(key_)) {
    delete this;
    return true;  // Unlink me, the object no longer needs a finalizer.
  }
  if (oracle->is_alive(key_)) {
    roots_do(cb);
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

void VmFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&key_));
}

bool VmFinalizerNode::weak_processing(bool in_closure_queue, RootCallback* cb, LivenessOracle* oracle) {
  ASSERT(!in_closure_queue);
  if (!oracle->has_active_finalizer(key_)) {
    // If the bit is not set on the object we can delete the finalizer node -
    // this is usually because an external byte array was neutered in RPC, so
    // there is nothing to do.  We don't traverse the finalizer list when
    // neutering for performance reasons, so clean up here.
    delete this;
    return true;  // Unlink me, the object no longer needs a finalizer.
  }
  if (oracle->is_alive(key_)) {
    cb->do_root(reinterpret_cast<Object**>(&key_));
    return false;  // Don't unlink me.
  }
  free_external_memory();
  delete this;
  return true;  // Unlink me.
}

void VmFinalizerNode::free_external_memory() {
  uint8* memory = null;
  word accounting_size = 0;
  if (is_byte_array(key_)) {
    ByteArray* byte_array = ByteArray::cast(key_);
    if (byte_array->external_tag() == MappedFileTag) return;  // TODO(erik): release mapped file, so flash storage can be reclaimed.
    ASSERT(byte_array->has_external_address());
    ByteArray::Bytes bytes(byte_array);
    memory = bytes.address();
    accounting_size = bytes.length();
    // Accounting size is 0 if the byte array is tagged, since we don't account
    // memory for Resources etc.
    ASSERT(byte_array->external_tag() == RawByteTag || byte_array->external_tag() == NullStructTag);
  } else if (is_string(key_)) {
    String* string = String::cast(key_);
    memory = string->as_external();
    // Add one because the strings are allocated with a null termination byte.
    accounting_size = string->length() + 1;
  }
  if (memory != null) {
    if (Flags::allocation) printf("Deleting external memory for string %p\n", memory);
    free(memory);
    heap_->owner()->unregister_external_allocation(accounting_size);
  }
}

}  // namespace.

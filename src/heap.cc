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

#include "heap.h"

#include "flags.h"
#include "heap_report.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "printing.h"
#include "process.h"
#include "scheduler.h"
#include "utils.h"
#include "vm.h"

#ifdef TOIT_FREERTOS
#include "esp_heap_caps.h"
#endif

namespace toit {

Instance* ObjectHeap::allocate_instance(Smi* class_id) {
  int size = program()->instance_size_for(class_id);
  TypeTag class_tag = program()->class_tag_for(class_id);
  return allocate_instance(class_tag, class_id, Smi::from(size));
}

Instance* ObjectHeap::allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size) {
  Instance* result = unvoid_cast<Instance*>(_allocate_raw(instance_size->value()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(class_id, class_tag);
  result->initialize(instance_size->value());
  return result;
}

Array* ObjectHeap::allocate_array(int length, Object* filler) {
  ASSERT(length >= 0);
  ASSERT(length <= Array::max_length_in_process());
  HeapObject* result = _allocate_raw(Array::allocation_size(length));
  if (result == null) {
    return null;  // Allocation failure.
  }
  // Initialize object.
  result->_set_header(program_, program_->array_class_id());
  Array::cast(result)->_initialize_no_write_barrier(length, filler);
  return Array::cast(result);
}

ByteArray* ObjectHeap::allocate_internal_byte_array(int length) {
  ASSERT(length >= 0);
  // Byte array should fit within one heap block.
  ASSERT(length <= ByteArray::max_internal_size_in_process());
  ByteArray* result = unvoid_cast<ByteArray*>(_allocate_raw(ByteArray::internal_allocation_size(length)));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program_, program_->byte_array_class_id());
  result->_initialize(length);
  return result;
}

Double* ObjectHeap::allocate_double(double value) {
  HeapObject* result = _allocate_raw(Double::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program_, program_->double_class_id());
  Double::cast(result)->_initialize(value);
  return Double::cast(result);
}

LargeInteger* ObjectHeap::allocate_large_integer(int64 value) {
  HeapObject* result = _allocate_raw(LargeInteger::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program_, program_->large_integer_class_id());
  LargeInteger::cast(result)->_initialize(value);
  return LargeInteger::cast(result);
}

String* ObjectHeap::allocate_internal_string(int length) {
  ASSERT(length >= 0);
  ASSERT(length <= String::max_internal_size_in_process());
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

bool InitialMemoryManager::allocate() {
  initial_chunk = ObjectMemory::allocate_chunk(null, TOIT_PAGE_SIZE);
  if (!initial_chunk) return false;
  heap_mutex = OS::allocate_mutex(6, "ObjectHeapMutex");
  return heap_mutex != null;
}

InitialMemoryManager::~InitialMemoryManager() {
  if (initial_chunk) {
    ObjectMemory::free_chunk(initial_chunk);
  }
  if (heap_mutex) {
    OS::dispose(heap_mutex);
  }
}

ObjectHeap::ObjectHeap(Program* program, Process* owner, Chunk* initial_chunk, Object** global_variables, Mutex* mutex)
    : program_(program)
    , owner_(owner)
    , two_space_heap_(program, this, initial_chunk)
    , external_memory_(0)
    , total_external_memory_(0)
    , global_variables_(global_variables)
    , mutex_(mutex) {
  if (!initial_chunk) return;
  task_ = allocate_task();
  ASSERT(task_);  // Should not fail, because a newly created heap has at least
                  // enough space for the task structure.
  // Currently the heap is empty and it has one block allocated for objects.
  update_pending_limit();
  limit_ = pending_limit_;
}

ObjectHeap::~ObjectHeap() {
  // If the process is still linked into the ProcessGroup then this is
  // only called with the scheduler lock.  Once the process has been
  // unlinked, this may be called without the scheduler lock.  We don't
  // use the lock of the ObjectHeap itself for this.  Implicitly called
  // from the destructor of the Process.
  free(global_variables_);

  while (auto finalizer = registered_finalizers_.remove_first()) {
    delete finalizer;
  }

  while (auto finalizer = runnable_finalizers_.remove_first()) {
    delete finalizer;
  }

  while (auto finalizer = registered_vm_finalizers_.remove_first()) {
    finalizer->free_external_memory(owner());
    delete finalizer;
  }

  delete finalizer_notifier_;

  OS::dispose(mutex_);

  ASSERT(object_notifiers_.is_empty());
}

word ObjectHeap::update_pending_limit() {
  word length = two_space_heap_.size() + external_memory_;
  // We call a new GC when the heap size has doubled, in an attempt to do
  // meaningful work before the next GC, but while still not allowing the heap
  // to grow too much when there is garbage to be found.
  word MIN = TOIT_PAGE_SIZE;
  word new_limit = Utils::max(MIN, length * 2);
  if (has_max_heap_size()) {
    // If the user set a max then we feel more justified in using up to that
    // much memory, so we allow the heap to quadruple before the next GC, but
    // limited by the max.
    new_limit = Utils::min(max_heap_size_, new_limit * 2);
  }
  pending_limit_ = new_limit;
  return new_limit;
}

word ObjectHeap::max_external_allocation() {
  if (!has_limit() && !has_max_heap_size()) return _UNLIMITED_EXPANSION;
  word total = external_memory_ + two_space_heap_.size();
  if (total >= limit_) return 0;
  return limit_ - total;
}

void ObjectHeap::register_external_allocation(word size) {
  if (size == 0) return;
  // Overloading on an atomic type makes an atomic += and returns new value.
  external_memory_ += size;
  total_external_memory_ += size;
}

void ObjectHeap::unregister_external_allocation(word size) {
  if (size == 0) return;
  // Overloading on an atomic type makes an atomic += and returns new value.
  uword old_external_memory = external_memory_;
  uword external_memory = external_memory_ -= size;
  USE(old_external_memory);
  USE(external_memory);
  // Check that the external memory does not underflow into 'negative' range.
  // This works even if we allocate so much external memory that we exceed the
  // range of signed 'word'.  This is possible on 32 bit Linux.
  ASSERT(old_external_memory >= external_memory);
}

ByteArray* ObjectHeap::allocate_external_byte_array(int length, uint8* memory, bool dispose, bool clear_content) {
  ByteArray* result = unvoid_cast<ByteArray*>(_allocate_raw(ByteArray::external_allocation_size()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program_, program_->byte_array_class_id());
  result->_initialize_external_memory(length, memory, clear_content);
  //  We add a specialized finalizer on the result so we can free the external memory.
  if (dispose) {
    if (Flags::allocation) printf("External memory for byte array %p [length = %d] setup for finalization.\n", memory, length);
    Process* process = owner();
    ASSERT(process != null);
    if (!process->add_vm_finalizer(result)) {
      set_last_allocation_result(ALLOCATION_OUT_OF_MEMORY);
      return null;  // Allocation failure.
    }
  }
  return result;
}

String* ObjectHeap::allocate_external_string(int length, uint8* memory, bool dispose) {
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
  if (dispose) {
    // Ensure finalizer is created for string with external memory.
    if (Flags::allocation) printf("External memory for string %p [length = %d] setup for finalization.\n", memory, length);
    Process* process = owner();
    ASSERT(process != null);
    if (!process->add_vm_finalizer(result)) {
      set_last_allocation_result(ALLOCATION_OUT_OF_MEMORY);
      return null;  // Allocation failure.
    }
  }
  return result;
}

Task* ObjectHeap::allocate_task() {
  // First allocate the stack.
  Stack* stack = allocate_stack(Stack::initial_length());
  if (stack == null) return null;  // Allocation failure.
  // Then allocate the task.
  Smi* task_id = program()->task_class_id();
  Task* result = unvoid_cast<Task*>(allocate_instance(program()->class_tag_for(task_id), task_id, Smi::from(program()->instance_size_for(task_id))));
  if (result == null) return null;  // Allocation failure.
  Task::cast(result)->_initialize(stack, Smi::from(owner()->next_task_id()));
  int fields = Instance::fields_from_size(program()->instance_size_for(result));
  for (int i = Task::ID_INDEX + 1; i < fields; i++) {
    result->at_put(i, program()->null_object());
  }
  return result;
}

Stack* ObjectHeap::allocate_stack(int length) {
  int size = Stack::allocation_size(length);
  Stack* result = unvoid_cast<Stack*>(_allocate_raw(size));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program(), program()->stack_class_id());
  Stack::cast(result)->_initialize(length);
  return result;
}

void ObjectHeap::iterate_roots(RootCallback* callback) {
  // Process the roots in the object heap.
  callback->do_root(reinterpret_cast<Object**>(&task_));
  callback->do_roots(global_variables_, program()->global_variables.length());
  for (auto root : external_roots_) callback->do_roots(root->slot(), 1);

  // Process roots in the object_notifiers_ list.
  for (ObjectNotifier* n : object_notifiers_) n->roots_do(callback);
  // Process roots in the runnable_finalizers_.
  for (FinalizerNode* node : runnable_finalizers_) {
    node->roots_do(callback);
  }
}

void ObjectHeap::iterate_chunks(void* context, process_chunk_callback_t* callback) {
  Locker locker(mutex_);
  two_space_heap_.iterate_chunks(context, callback);
}

GcType ObjectHeap::gc(bool try_hard) {
  Locker locker(mutex_);
  GcType type = two_space_heap_.collect_new_space(try_hard);
  gc_count_++;
  if (type != NEW_SPACE_GC) {
    full_gc_count_++;
    if (type == COMPACTING_GC) full_compacting_gc_count_++;
    // Update the pending limit that will be installed after the current
    // primitive (that caused the GC) completes.
    update_pending_limit();
  }
  // Use only the hard limit for the rest of this primitive.  We don't want to
  // trigger any heuristic GCs before the primitive is over or we might cause a
  // triple GC, which throws an exception.
  limit_ = max_heap_size_;
  return type;
}

// Install a new allocation limit at the end of a primitive that caused a GC.
void ObjectHeap::install_heap_limit() {
  word total = external_memory_ + two_space_heap_.size();
  if (total > pending_limit_) {
    // If we already went over the heuristic limit that triggers a new GC we set
    // a flag that means the next scavenge won't promote into old space.
    two_space_heap_.set_promotion_failed();
  }
  limit_ = pending_limit_;
}

void ObjectHeap::process_registered_finalizers(RootCallback* ss, LivenessOracle* from_space) {
  // Process the registered finalizer list.
  if (!registered_finalizers_.is_empty() && Flags::tracegc && Flags::verbose) printf(" - Processing registered finalizers\n");
  ObjectHeap* heap = this;
  registered_finalizers_.remove_wherever([ss, heap, from_space](FinalizerNode* node) -> bool {
    bool is_alive = from_space->is_alive(node->key());
    if (!is_alive) {
      // Clear the key so it is not retained.
      node->set_key(heap->program()->null_object());
    }
    node->roots_do(ss);
    if (is_alive && Flags::tracegc && Flags::verbose) printf(" - Finalizer %p is alive\n", node);
    if (is_alive) return false;  // Keep node in list.
    // From here down, the node is going to be unlinked by returning true.
    if (Flags::tracegc && Flags::verbose) printf(" - Finalizer %p is unreachable\n", node);
    heap->runnable_finalizers_.append(node);
    return true; // Remove node from list.
  });
}

void ObjectHeap::process_registered_vm_finalizers(RootCallback* ss, LivenessOracle* from_space) {
  // Process registered VM finalizers.
  registered_vm_finalizers_.remove_wherever([ss, this, from_space](VmFinalizerNode* node) -> bool {
    bool is_alive = from_space->is_alive(node->key());

    if (is_alive && Flags::tracegc && Flags::verbose) printf(" - Finalizer %p is alive\n", node);
    if (is_alive) {
      node->roots_do(ss);
      return false; // Keep node in list.
    }
    if (Flags::tracegc && Flags::verbose) printf(" - Processing registered finalizer %p for external memory.\n", node);
    node->free_external_memory(owner());
    delete node;
    return true; // Remove node from list.
  });
}

bool ObjectHeap::has_finalizer(HeapObject* key, Object* lambda) {
  for (FinalizerNode* node : registered_finalizers_) {
    if (node->key() == key) return true;
  }
  return false;
}

bool ObjectHeap::add_finalizer(HeapObject* key, Object* lambda) {
  // We should already have checked whether the object is already registered.
  ASSERT(!has_finalizer(key, lambda));
  auto node = _new FinalizerNode(key, lambda);
  if (node == null) return false;  // Allocation failed.
  registered_finalizers_.append(node);
  return true;
}

bool ObjectHeap::add_vm_finalizer(HeapObject* key) {
  // We should already have checked whether the object is already registered.
  auto node = _new VmFinalizerNode(key);
  if (node == null) return false;  // Allocation failed.
  registered_vm_finalizers_.append(node);
  return true;
}

bool ObjectHeap::remove_finalizer(HeapObject* key) {
  bool found = false;
  registered_finalizers_.remove_wherever([key, &found](FinalizerNode* node) -> bool {
    if (node->key() == key) {
      delete node;
      found = true;
      return true;
    }
    return false;
  });
  return found;
}

bool ObjectHeap::remove_vm_finalizer(HeapObject* key) {
  bool found = false;
  registered_vm_finalizers_.remove_wherever([key, &found](VmFinalizerNode* node) -> bool {
    if (node->key() == key) {
      delete node;
      found = true;
      return true;
    }
    return false;
  });
  return found;
}

Object* ObjectHeap::next_finalizer_to_run() {
  FinalizerNode* node = runnable_finalizers_.remove_first();
  if (node == null) {
    return program()->null_object();
  }

  Object* result = node->lambda();
  delete node;
  return result;
}

ObjectNotifier::ObjectNotifier(Process* process, Object* object)
    : process_(process)
    , object_(object)
    , message_(null) {
  process_->object_heap()->object_notifiers_.prepend(this);
}

ObjectNotifier::~ObjectNotifier() {
  unlink();
  if (message_ && message_->clear_object_notifier()) delete message_;
}

void ObjectNotifier::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&object_));
}

}

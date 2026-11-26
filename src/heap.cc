// Copyright (C) 2023 Toitware ApS.
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
#include "heap_roots.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "printing.h"
#include "process.h"
#include "scheduler.h"
#include "utils.h"
#include "vm.h"

#ifdef TOIT_ESP32
#include "esp_heap_caps.h"
#endif

namespace toit {

Instance* ObjectHeap::allocate_instance(Smi* class_id) {
  word size = program()->allocation_instance_size_for(class_id);
  TypeTag class_tag = program()->class_tag_for(class_id);
  if (size < Instance::HEADER_SIZE) {
    set_last_allocation_result(ALLOCATION_HIT_LIMIT);
    return null;
  }
  uword result_word = allocate_new_space(size);
  if (!result_word) return null;  // Allocation failure.
  // Initialize object.
  Object** fields = reinterpret_cast<Object**>(result_word + Instance::HEADER_SIZE);
  Utils::fill_words<Object*>(fields, Instance::fields_from_size(size), program()->null_object());
  HeapObject* result = HeapObject::from_address(result_word);
  result->_set_header(class_id, class_tag);
  return Instance::cast(result);
}

Array* ObjectHeap::allocate_array(word length, Object* filler) {
  if (length < 0 || length > Array::max_length_in_process()) return null;
  HeapObject* result = _allocate_raw(Array::allocation_size(length));
  if (result == null) {
    return null;  // Allocation failure.
  }
  // Initialize object.
  result->_set_header(program_, program_->array_class_id());
  Array::cast(result)->_initialize_no_write_barrier(length, filler);
  return Array::cast(result);
}

ByteArray* ObjectHeap::allocate_internal_byte_array(word length) {
  // Byte array should fit within one heap block.
  if (length < 0 || length > ByteArray::max_internal_size_in_process()) return null;
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

String* ObjectHeap::allocate_internal_string(word length) {
  ASSERT(length >= 0);
  ASSERT(length <= String::max_internal_size_in_process());
  HeapObject* result = _allocate_raw(String::internal_allocation_size(length));
  if (result == null) return null;
  // Initialize object.
  Smi* string_id = program()->string_class_id();
  result->_set_header(string_id, program()->class_tag_for(string_id));
  String::cast(result)->_set_length(length);
  String::cast(result)->_raw_set_hash_code(String::NO_HASH_CODE);
  String::MutableBytes bytes(String::cast(result));
  bytes._set_end();
  ASSERT(bytes.length() == length);
  return String::cast(result);
}

bool InitialMemoryManager::can_allocate_task(Program* program) {
  Smi* id = program->task_class_id();
  if (!is_smi(id)) return false;
  word index = Smi::value(id);
  if (index < 0 || index >= program->class_bits.length()) return false;
  int bits = program->class_bits[index];
  if (Program::class_tag_from_class_bits(bits) != TASK_TAG) return false;
  word task_size = Program::instance_size_from_class_bits(bits);
  word stack_size = Stack::allocation_size(Stack::initial_length(program));
  return task_size >= Instance::allocation_size(Task::ID_INDEX + 1) &&
         stack_size + task_size + SENTINEL_SIZE <= TOIT_PAGE_SIZE;
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
  // Opt-in (src/sandbox_gc.h): a sandboxed process may use the copying collector.
  if (owner != null && sandbox_copying_gc_wanted(owner)) two_space_heap_.enable_copying_gc();
  task_ = allocate_task();
  ASSERT(task_);  // ProcessGroup::create checked both objects fit on the initial page.
  // Currently the heap is empty and it has one block allocated for objects.
  update_pending_limit();
  limit_ = pending_limit_;
}

static void clean_up_finalizers(FinalizerNodeFifo* list) {
  while (auto finalizer = list->remove_first()) {
    finalizer->heap_dying();
    delete finalizer;
  }
}

ObjectHeap::~ObjectHeap() {
  // If the process is still linked into the ProcessGroup then this is
  // only called with the scheduler lock.  Once the process has been
  // unlinked, this may be called without the scheduler lock.  We don't
  // use the lock of the ObjectHeap itself for this.  Implicitly called
  // from the destructor of the Process.
  free(global_variables_);

  clean_up_finalizers(&registered_callback_finalizers_);
  clean_up_finalizers(&runnable_finalizers_);
  clean_up_finalizers(&registered_vm_finalizers_);

  OS::dispose(mutex_);

  ASSERT(object_notifiers_.is_empty());
}

// Heap space and externally backed objects can together exceed a signed word.
static uword combined_heap_bytes(uword internal, uword external) {
  if (external > UINTPTR_MAX - internal) return UINTPTR_MAX;
  return internal + external;
}

uword ObjectHeap::reserved_heap_bytes() const {
  return combined_heap_bytes(two_space_heap_.size(), external_memory());
}

static word doubled_heap_limit(uword bytes) {
  if (bytes > INTPTR_MAX / 2) return INTPTR_MAX;
  return static_cast<word>(bytes * 2);
}

word ObjectHeap::update_pending_limit() {
  word next = doubled_heap_limit(reserved_heap_bytes());
  if (next < TOIT_PAGE_SIZE) next = TOIT_PAGE_SIZE;
  if (has_max_heap_size()) {
    // Allow twice as much growth when the configured maximum bounds it.
    next = doubled_heap_limit(static_cast<uword>(next));
    if (next > max_heap_size_) next = max_heap_size_;
  }
  pending_limit_ = next;
  return next;
}

word ObjectHeap::max_external_allocation() {
  if (!has_limit() && !has_max_heap_size()) return _UNLIMITED_EXPANSION;
  uword total = reserved_heap_bytes();
  if (limit_ < 0 || total > static_cast<uword>(limit_)) return -1;
  return limit_ - static_cast<word>(total);
}

void ObjectHeap::register_external_allocation(word size) {
  if (size == 0) return;
  // The live and lifetime counts are updated independently.
  ASSERT(size >= 0);
  external_memory_.fetch_add(static_cast<uword>(size));
  total_external_memory_.fetch_add(size, std::memory_order_relaxed);
}

void ObjectHeap::unregister_external_allocation(word size) {
  if (size == 0) return;
  ASSERT(size >= 0);
  uword released = static_cast<uword>(size);
  uword before = external_memory_.fetch_sub(released);
  USE(before);
  ASSERT(before >= released);
}

ByteArray* ObjectHeap::allocate_external_byte_array(word length, uint8* memory, bool dispose, bool clear_content) {
  ByteArray* result = unvoid_cast<ByteArray*>(_allocate_raw(ByteArray::external_allocation_size()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program_, program_->byte_array_class_id());
  result->_initialize_external_memory(length, memory, clear_content);
  //  We add a specialized finalizer on the result so we can free the external memory.
  if (dispose) {
    if (Flags::allocation) printf("External memory for byte array %p [length = %" PRIdPTR "] setup for finalization.\n", memory, length);
    Process* process = owner();
    ASSERT(process != null);
    if (!add_vm_finalizer(result)) {
      set_last_allocation_result(ALLOCATION_OUT_OF_MEMORY);
      return null;  // Allocation failure.
    }
  }
  return result;
}

String* ObjectHeap::allocate_external_string(word length, uint8* memory, bool dispose) {
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
    String::MutableBytes bytes(String::cast(result));
    bytes._set_end();
  }
  if (dispose) {
    // Ensure finalizer is created for string with external memory.
    if (Flags::allocation) printf("External memory for string %p [length = %" PRIdPTR "] setup for finalization.\n", memory, length);
    Process* process = owner();
    ASSERT(process != null);
    if (!add_vm_finalizer(result)) {
      set_last_allocation_result(ALLOCATION_OUT_OF_MEMORY);
      return null;  // Allocation failure.
    }
  }
  return result;
}

Task* ObjectHeap::allocate_task() {
  // IDs are unique within the process and must fit both a Smi and the profiler's int.
  if (!owner()->has_task_id()) {
    set_last_allocation_result(ALLOCATION_HIT_LIMIT);
    return null;
  }
  // First allocate the stack.
  Stack* stack = allocate_stack(Stack::initial_length(program()));
  if (stack == null) return null;  // Allocation failure.
  // Then allocate the task.
  Smi* task_id = program()->task_class_id();
  Task* result = unvoid_cast<Task*>(allocate_instance(task_id));
  if (result == null) return null;  // Allocation failure.
  Task::cast(result)->_initialize(stack, Smi::from(owner()->next_task_id()));
  return result;
}

Stack* ObjectHeap::allocate_stack(word length) {
  word size = Stack::allocation_size(length);
  Stack* result = unvoid_cast<Stack*>(_allocate_raw(size));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program(), program()->stack_class_id());
  Stack::cast(result)->_initialize(length);
  // The verified core takes a view of every word, including unused slots.
  if (program()->is_format2()) {
    Utils::fill_words<Object*>(result->_stack_limit_addr(), length, Smi::zero());
  }
  return result;
}

void ObjectHeap::iterate_roots(RootCallback* callback) {
  // Process the roots in the object heap.
  callback->do_root(reinterpret_cast<Object**>(&task_));
  callback->do_roots(global_variables_, program()->global_variables.length());
  for (auto root : external_roots_) {
    callback->do_roots(root->slot(), 1);
  }

  // Process roots in the object_notifiers_ list.
  for (ObjectNotifier* n : object_notifiers_) {
    n->roots_do(callback);
  }
}

void ObjectHeap::iterate_chunks(void* context, process_chunk_callback_t* callback) {
  Locker locker(mutex_);
  two_space_heap_.iterate_chunks(context, callback);
}

int ObjectHeap::next_gc_count(int count) {
  const word limit = Smi::MAX_SMI_VALUE < INT32_MAX ? Smi::MAX_SMI_VALUE : INT32_MAX;
  if (count == limit) return 0;
  return count + 1;
}

void ObjectHeap::record_gc(GcType type) {
  gc_count_ = next_gc_count(gc_count_);
  if (type != NEW_SPACE_GC) full_gc_count_ = next_gc_count(full_gc_count_);
  if (type == COMPACTING_GC) full_compacting_gc_count_ = next_gc_count(full_compacting_gc_count_);
}

GcType ObjectHeap::gc(bool try_hard) {
  Locker locker(mutex_);
  GcType type = two_space_heap_.collect(try_hard);
  record_gc(type);
  advance_v2_epoch();
  if (type != NEW_SPACE_GC) {
    // Update the pending limit that will be installed after the current
    // primitive (that caused the GC) completes.
    update_pending_limit();
    // Use only the hard limit for the rest of this primitive.  We don't want to
    // trigger any heuristic GCs before the primitive is over or we might cause a
    // triple GC, which throws an exception.
    limit_ = max_heap_size_;
  }
  // Will be cleared again immediately if the GC succeeded in freeing up enough
  // to complete the primitive.
  retrying_primitive_ = true;
  return type;
}

// Install a new allocation limit at the end of a primitive that caused a GC.
void ObjectHeap::install_heap_limit() {
  uword total = reserved_heap_bytes();
  if (pending_limit_ < 0 || total > static_cast<uword>(pending_limit_)) {
    // If we already went over the heuristic limit that triggers a new GC we set
    // a flag that means the next scavenge won't promote into old space.
    two_space_heap_.set_promotion_failed();
  }
  limit_ = pending_limit_;
}

void ObjectHeap::process_registered_callback_finalizers(RootCallback* ss, LivenessOracle* from_space) {
  process_registered_finalizers_helper(&registered_callback_finalizers_, ss, from_space, false);
}

void ObjectHeap::process_registered_vm_finalizers(RootCallback* ss, LivenessOracle* from_space) {
  process_registered_finalizers_helper(&registered_vm_finalizers_, ss, from_space, false);
}

void ObjectHeap::process_finalizer_queue(RootCallback* ss, LivenessOracle* from_space) {
  process_registered_finalizers_helper(&runnable_finalizers_, ss, from_space, true);
}

void ObjectHeap::process_registered_finalizers_helper(FinalizerNodeFifo* list, RootCallback* ss, LivenessOracle* from_space, bool in_closure_queue) {
  list->remove_wherever([ss, from_space, in_closure_queue](FinalizerNode* node) -> bool {
    return node->weak_processing(in_closure_queue, ss, from_space);
  });
}

#ifndef TOIT_FREERTOS
void ObjectHeap::dump_finalizer_nodes(void* context, void (*f)(void* context, int list, int kind, void* node, Object* key, Object* lambda)) {
  for (auto node : registered_callback_finalizers_) {
    auto callable = static_cast<CallableFinalizerNode*>(node);
    f(context, 0, callable->keep_after_callback() ? 1 : 0, node, node->key(), callable->lambda());
  }
  for (auto node : runnable_finalizers_) {
    auto callable = static_cast<CallableFinalizerNode*>(node);
    f(context, 1, callable->keep_after_callback() ? 1 : 0, node, node->key(), callable->lambda());
  }
  for (auto node : registered_vm_finalizers_) {
    f(context, 2, 4, node, node->key(), null);
  }
}
#endif

void ObjectHeap::iterate_finalization_roots(RootCallback* cb) {
  for (auto finalizer : registered_callback_finalizers_) finalizer->roots_do(cb);
  for (auto finalizer : registered_vm_finalizers_) finalizer->roots_do(cb);
  for (auto finalizer : runnable_finalizers_) finalizer->roots_do(cb);
}

bool ObjectHeap::add_callable_finalizer(Instance* key, Object* lambda, bool weak_map) {
  // The primitive rejects keys that already have an active finalizer.
  ASSERT(!key->has_active_finalizer());
  if (!prepend_callable_finalizer(key, lambda, weak_map)) return false;
  key->set_has_active_finalizer();
  return true;
}

bool ObjectHeap::prepend_callable_finalizer(Instance* key, Object* lambda, bool weak_map) {
  CallableFinalizerNode* node;
  if (weak_map) {
    ASSERT(!key->can_be_toit_finalized(program()));
    ASSERT(!key->has_active_finalizer());
    auto weak_node = _new WeakMapFinalizerNode(key, lambda, this);
    node = weak_node;
  } else {
    ASSERT(key->can_be_toit_finalized(program()));
    ASSERT(!key->has_active_finalizer());
    auto ordinary_node = _new ToitFinalizerNode(key, lambda, this);
    node = ordinary_node;
  }
  if (node == null) return false;  // Allocation failed.
  registered_callback_finalizers_.prepend(node);
  return true;
}

void ObjectHeap::remove_callable_finalizer(Instance* key) {
  unlink_callable_finalizers(key);
  key->clear_has_active_finalizer();
}

void ObjectHeap::unlink_callable_finalizers(Instance* key) {
  // Unlink the node now instead of at the next GC. Otherwise a program that
  // adds and removes a finalizer in a loop without allocating grows the list
  // (malloced memory) without bound, and the nodes of a key that gets a new
  // finalizer before the next GC stay on the list for as long as the key
  // lives, since the GC only looks at the key's finalizer bit.
  registered_callback_finalizers_.remove_wherever([key](FinalizerNode* node) -> bool {
    if (node->key() != key) return false;
    delete node;
    return true;
  });
}

bool ObjectHeap::add_vm_finalizer(HeapObject* key) {
  ASSERT(!key->can_be_toit_finalized(program()));
  // We should already have checked whether the object is already registered.
  auto node = _new VmFinalizerNode(key, this);
  if (node == null) return false;  // Allocation failed.
  registered_vm_finalizers_.append(node);
  key->set_has_active_finalizer();
  return true;
}

Object* ObjectHeap::next_finalizer_to_run() {
  auto node = static_cast<CallableFinalizerNode*>(runnable_finalizers_.remove_first());
  if (node == null) {
    return program()->null_object();
  }

  Object* result = node->lambda();
  if (node->keep_after_callback()) {
    registered_callback_finalizers_.prepend(node);
  } else {
    delete node;
  }
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

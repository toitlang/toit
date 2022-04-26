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

#ifdef LEGACY_GC

class ScavengeScope : public Locker {
 public:
  ScavengeScope(HeapMemory* heap_memory, RawHeap* heap)
      : Locker(heap_memory->mutex())
      , _heap_memory(heap_memory)
      , _heap(heap) {
    heap_memory->enter_scavenge(heap);
  }

  ~ScavengeScope() {
    _heap_memory->leave_scavenge(_heap);
  }

 private:
  HeapMemory* _heap_memory;
  RawHeap* _heap;
};

#endif

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
  result->_set_header(_program, _program->array_class_id());
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
  result->_set_header(_program, _program->byte_array_class_id());
  result->_initialize(length);
  return result;
}

Double* ObjectHeap::allocate_double(double value) {
  HeapObject* result = _allocate_raw(Double::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->double_class_id());
  Double::cast(result)->_initialize(value);
  return Double::cast(result);
}

LargeInteger* ObjectHeap::allocate_large_integer(int64 value) {
  HeapObject* result = _allocate_raw(LargeInteger::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->large_integer_class_id());
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

#ifdef LEGACY_GC

HeapObject* ObjectHeap::_allocate_raw(int byte_size) {
  ASSERT(byte_size > 0);
  ASSERT(byte_size <= max_allocation_size());
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

ObjectHeap::AllocationResult ObjectHeap::_expand() {
  word used = (_blocks.length() << TOIT_PAGE_SIZE_LOG2) + _external_memory;
  if (_limit != 0 && used >= _limit) {
#ifdef TOIT_GC_LOGGING
    printf("[gc @ %p%s | soft limit reached (%zd >= %zd)]\n",
        owner(), VM::current()->scheduler()->is_boot_process(owner()) ? "*" : " ",
        used, _limit);
#endif
    return ALLOCATION_HIT_LIMIT;
  }
  Block* block = VM::current()->heap_memory()->allocate_block(this);
  if (block == null) return ALLOCATION_OUT_OF_MEMORY;
  _blocks.append(block);
  return ALLOCATION_SUCCESS;
}

class ScavengeState : public RootCallback {
 public:
  explicit ScavengeState(ObjectHeap* heap)
      : _heap(heap), _process(heap->owner()), _scope(VM::current()->heap_memory(), heap) {
    blocks.append(VM::current()->heap_memory()->allocate_block_during_scavenge(heap));
  }

  HeapObject* allocate(int byte_size) {
    HeapObject* result = blocks.last()->allocate_raw(byte_size);
    if (result == null) {
      blocks.append(VM::current()->heap_memory()->allocate_block_during_scavenge(_heap));
      result = blocks.last()->allocate_raw(byte_size);
      if (result == null) {
        FATAL("Cannot allocate memory");
      }
    }
    return result;
  }

  // Copy and install forward address in from.
  HeapObject* copy_object(HeapObject* from) {
    int object_size = from->size(_heap->program());
    HeapObject* result;
    if (from->is_stack()) {
      Stack* stack = Stack::cast(from);
      int length = stack->length();
      // Shrink stacks so they have as much space left as newly allocated stacks.
      // TODO(anders): Skip the active Task, or perhaps use different target?
      int target = stack->top() - Stack::initial_length();
      int new_length = length - Utils::max(0, target);
      result = allocate(Stack::allocation_size(new_length));
      // As the size could have changed, use stack-specific method for copying content.
      stack->copy_to(result, new_length);
    } else {
      result = allocate(object_size);
      // Copy the object content raw to the destination.
      memcpy(result->_raw_at(0), from->_raw_at(0), Utils::round_up(object_size, WORD_SIZE));
    }
    if (Flags::tracegc && Flags::verbose) printf(" - copy object from %p to %p\n", from, result);
    // Insert forwarding pointer in from object overwriting the object's Smi header.
    // The fact that the header is a Smi and the forwarding pointer is a heap pointer,
    // allows us to distinguish the two.
    from->_at_put(HeapObject::HEADER_OFFSET, result);
    ASSERT(from->has_forwarding_address());
    return result;
  }

  // Callback defined in RootCallback.
  virtual void do_roots(Object** roots, int length) {
    for (int i = 0; i < length; i++) {
      if (Flags::tracegc && Flags::verbose) printf(" - do root %p\n", &roots[i]);
      Object* content = roots[i];
      if (!content->is_heap_object()) continue;  // Do nothing.
      HeapObject* heap_object = HeapObject::cast(content);
      if (heap_object->on_program_heap(_process)) continue;  // Do nothing, content is outside heap.
      roots[i] = heap_object->has_forwarding_address()  // Has the object already been copied to new-space.
          ? heap_object->forwarding_address() // Update the root with the forwarding.
          : copy_object(heap_object);         // Otherwise, copy the object.
    }
  }

  void process_to_objects(ObjectHeap::Iterator& objects) {
    while (!objects.eos()) {
      if (Flags::tracegc && Flags::verbose) printf(" - process object %p\n", objects.current());
      objects.current()->roots_do(_heap->program(), this);
      objects.advance();
    }
  }

  void process_to_space() {
    ObjectHeap::Iterator objects(blocks, _heap->program());
    while (!objects.eos()) process_to_objects(objects);
    ASSERT(objects.eos());
  }

  BlockList blocks;
 private:
  ObjectHeap* _heap;
  Process* _process;
  ScavengeScope _scope;
};

#endif  // def LEGACY_GC

bool InitialMemoryManager::allocate() {
#ifdef LEGACY_GC
  initial_memory = VM::current()->heap_memory()->allocate_initial_block();
#else
  initial_memory = ObjectMemory::allocate_chunk(null, TOIT_PAGE_SIZE);
#endif
  return initial_memory != null;
}

InitialMemoryManager::~InitialMemoryManager() {
  if (initial_memory) {
#ifdef LEGACY_GC
    VM::current()->heap_memory()->free_unused_block(initial_memory);
#else
    ObjectMemory::free_chunk(initial_memory);
#endif
  }
}

#ifdef LEGACY_GC
ObjectHeap::ObjectHeap(Program* program, Process* owner, Block* block)
    : RawHeap(owner)
    , _program(program)
    , _external_memory(0) {
  if (block == null) return;
  _blocks.append(block);
#else
ObjectHeap::ObjectHeap(Program* program, Process* owner, InitialMemory* initial_memory)
    : _program(program)
    , _owner(owner)
    , _two_space_heap(program, this, initial_memory)
    , _external_memory(0) {
  if (!initial_memory) return;
#endif
  _task = allocate_task();
  ASSERT(_task);  // Should not fail, because a newly created heap has at least
                  // enough space for the task structure.
  _global_variables = program->global_variables.copy();
  // Currently the heap is empty and it has one block allocated for objects.
  _limit = _pending_limit = _calculate_limit();
}

ObjectHeap::~ObjectHeap() {
  free(_global_variables);

  while (auto finalizer = _registered_finalizers.remove_first()) {
    delete finalizer;
  }

  while (auto finalizer = _runnable_finalizers.remove_first()) {
    delete finalizer;
  }

  while (auto finalizer = _registered_vm_finalizers.remove_first()) {
    finalizer->free_external_memory(owner());
    delete finalizer;
  }

  delete _finalizer_notifier;

  ASSERT(_object_notifiers.is_empty());

#ifdef LEGACY_GC
  // TODO: ObjectHeap deletion in new GC.
  // Deleting a heap is like a scavenge where nothing survives.
  ScavengeScope scope(VM::current()->heap_memory(), this);
  _blocks.free_blocks(this);
#endif
}

#ifdef LEGACY_GC
word ObjectHeap::_calculate_limit() {
  word length = ((_blocks.length() + 2) << TOIT_PAGE_SIZE_LOG2) + _external_memory;
  word new_limit = Utils::max(_MIN_BLOCK_LIMIT << TOIT_PAGE_SIZE_LOG2, length + length / 2);
  if (has_max_heap_size()) {
    new_limit = Utils::min(_max_heap_size, new_limit);
  }
  return new_limit;
}

bool ObjectHeap::should_allow_external_allocation(word size) {
  if (_limit == 0) return true;
  word external_allowed = _limit - (Utils::min(_MIN_BLOCK_LIMIT, _blocks.length()) << TOIT_PAGE_SIZE_LOG2);
  return external_allowed >= _external_memory + _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD + size;
}

# else

word ObjectHeap::_calculate_limit() {
  word length = _two_space_heap.used() + _external_memory;
  word MIN = 4096;
  word new_limit = Utils::max(MIN, length + length / 2);
  if (has_max_heap_size()) {
    new_limit = Utils::min(_max_heap_size, new_limit);
  }
  return new_limit;
}

bool ObjectHeap::should_allow_external_allocation(word size) {
  if (_limit == 0) return true;
  word external_allowed = _limit - 4096;
  return external_allowed >= _external_memory + _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD + size;
}

#endif

void ObjectHeap::register_external_allocation(word size) {
  if (size == 0) return;
  // Overloading on an atomic type makes an atomic += and returns new value.
  _external_memory += _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD + size;
#ifdef LEGACY_GC
  _total_bytes_allocated += size;
#else
  _external_bytes_allocated += size;
#endif
}

void ObjectHeap::unregister_external_allocation(word size) {
  if (size == 0) return;
  // Overloading on an atomic type makes an atomic += and returns new value.
  uword old_external_memory = _external_memory;
  uword external_memory = _external_memory -= _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD + size;
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
  result->_set_header(_program, _program->byte_array_class_id());
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
  stack->set_task(result);
  return result;
}

void ObjectHeap::set_task(Task* task) {
  _task = task;
  // The interpreter doesn't use the write barrier when pushing to the
  // stack so we have to add it here.
  GcMetadata::insert_into_remembered_set(task->stack());
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

#ifdef TOIT_GC_LOGGING
static word format(word n) {
  return (n > 9999) ? (n >> KB_LOG2) : n;
}
static const char* format_unit(word n) {
  return (n > 9999) ? "K" : "";
}
#define FORMAT(n) format(n), format_unit(n)
#endif

void ObjectHeap::iterate_roots(RootCallback* callback) {
  // Process the roots in the object heap.
  callback->do_root(reinterpret_cast<Object**>(&_task));
  callback->do_roots(_global_variables, program()->global_variables.length());
  for (auto root : _external_roots) callback->do_roots(root->slot(), 1);

  // Process roots in the _object_notifiers list.
  for (ObjectNotifier* n : _object_notifiers) n->roots_do(callback);
  // Process roots in the _runnable_finalizers.
  for (FinalizerNode* node : _runnable_finalizers) {
    node->roots_do(callback);
  }
}

#ifndef LEGACY_GC

int ObjectHeap::gc() {
  _two_space_heap.collect_new_space();
  _gc_count++;
  _pending_limit = _calculate_limit();  // GC limit to install after next GC.
  _limit = _max_heap_size;  // Only the hard limit for the rest of this primitive.
  return 0;  // TODO: Return blocks freed?
}

#else

class HasForwardingAddress : public LivenessOracle {
 public:
  virtual bool is_alive(HeapObject* object) override {
    return object->has_forwarding_address();
  }
};

int ObjectHeap::gc() {
  if (program() == null) FATAL("cannot gc external process");

  word blocks_before = _blocks.length();
#ifdef TOIT_GC_LOGGING
  int64 start_time = OS::get_monotonic_time();
  word external_memory_before = _external_memory;
#ifdef TOIT_FREERTOS
  multi_heap_info_t before;
  heap_caps_get_info(&before, MALLOC_CAP_8BIT);
#endif //TOIT_FREERTOS
#endif //TOIT_GC_LOGGING

  enter_gc();
  // Reset this until we get a new failure after GC.
  set_last_allocation_result(ALLOCATION_SUCCESS);
  if (Flags::tracegc) {
    printf("[Begin object scavenge #(%zdk, %zdk, external %zdk)]\n",
           _blocks.length() << (TOIT_PAGE_SIZE_LOG2 - KB_LOG2),
           _limit >> KB_LOG2,
           _external_memory >> KB_LOG2);
  }

  { ScavengeState ss(this);

    iterate_roots(&ss);

    // Process the to space.
    Iterator objects(ss.blocks, program());
    while (!objects.eos()) ss.process_to_objects(objects);

    HasForwardingAddress is_alive_oracle;

    process_registered_finalizers(&ss, &is_alive_oracle);

    // Process the finalizers in the to space.
    while (!objects.eos()) ss.process_to_objects(objects);
    ASSERT(objects.eos());

    process_registered_vm_finalizers(&ss, &is_alive_oracle);

    // Complete the scavenge.
    while (!objects.eos()) ss.process_to_objects(objects);
    ASSERT(objects.eos());

    take_blocks(&ss.blocks);
  }

  _pending_limit = _calculate_limit();  // GC limit to install after next GC.
  _limit = _max_heap_size;  // Only the hard limit for the rest of this primitive.
  if (Flags::tracegc) {
    printf("[End object scavenge #(%zdk, %zdk, external %zdk)]\n",
        _blocks.length() << (TOIT_PAGE_SIZE_LOG2 - KB_LOG2),
        _pending_limit >> KB_LOG2,
        _external_memory >> KB_LOG2);
  }
  _gc_count++;
  leave_gc();

  word blocks_after = _blocks.length();
#ifdef TOIT_GC_LOGGING
  word toit_before = (blocks_before << TOIT_PAGE_SIZE_LOG2) + external_memory_before;
  word toit_after = (blocks_after << TOIT_PAGE_SIZE_LOG2) + _external_memory;
  int64 microseconds = OS::get_monotonic_time() - start_time;
#ifdef TOIT_FREERTOS
  multi_heap_info_t after;
  heap_caps_get_info(&after, MALLOC_CAP_8BIT);
  word capacity_before = before.total_allocated_bytes + before.total_free_bytes;
  word capacity_after = after.total_allocated_bytes + after.total_free_bytes;
  int used_before = before.total_allocated_bytes * 100 / capacity_before;
  int used_after = after.total_allocated_bytes * 100 / capacity_after;
  printf("[gc @ %p%s "
         "| objects: %zd%s/%zd%s -> %zd%s/%zd%s "
         "| overall: %zd%s/%zd%s@%d%% -> %zd%s/%zd%s@%d%% "
         "| free: %zd%s/%zd%s -> %zd%s/%zd%s "
         "| %d.%03dms]\n",
      owner(), VM::current()->scheduler()->is_boot_process(owner()) ? "*" : " ",
      FORMAT(external_memory_before), FORMAT(toit_before),                           // objects-before
      FORMAT(_external_memory), FORMAT(toit_after),                                  // objects-after
      FORMAT(before.total_allocated_bytes), FORMAT(capacity_before), used_before,    // overall-before
      FORMAT(after.total_allocated_bytes), FORMAT(capacity_after), used_after,       // overall-after
      FORMAT(before.largest_free_block), FORMAT(before.total_free_bytes),            // free-before
      FORMAT(after.largest_free_block), FORMAT(after.total_free_bytes),              // free-after
      static_cast<int>(microseconds / 1000), static_cast<int>(microseconds % 1000)); // time
#else
  printf("[gc @ %p%s "
         "| objects: %zd%s/%zd%s -> %zd%s/%zd%s "
         "| %d.%03dms]\n",
      owner(), VM::current()->scheduler()->is_boot_process(owner()) ? "*" : " ",
      FORMAT(external_memory_before), FORMAT(toit_before),                           // objects-before
      FORMAT(_external_memory), FORMAT(toit_after),                                  // objects-after
      static_cast<int>(microseconds / 1000), static_cast<int>(microseconds % 1000)); // time
#endif // TOIT_FREERTOS
#endif // TOIT_GC_LOGGING
  return blocks_before - blocks_after;
}

#endif  // LEGACY_GC

void ObjectHeap::process_registered_finalizers(RootCallback* ss, LivenessOracle* from_space) {
  // Process the registered finalizer list.
  if (!_registered_finalizers.is_empty() && Flags::tracegc && Flags::verbose) printf(" - Processing registered finalizers\n");
  ObjectHeap* heap = this;
  _registered_finalizers.remove_wherever([ss, heap, from_space](FinalizerNode* node) -> bool {
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
    heap->_runnable_finalizers.append(node);
    return true; // Remove node from list.
  });
}

void ObjectHeap::process_registered_vm_finalizers(RootCallback* ss, LivenessOracle* from_space) {
  // Process registered VM finalizers.
  _registered_vm_finalizers.remove_wherever([ss, this, from_space](VMFinalizerNode* node) -> bool {
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
  for (FinalizerNode* node : _registered_finalizers) {
    if (node->key() == key) return true;
  }
  return false;
}

bool ObjectHeap::add_finalizer(HeapObject* key, Object* lambda) {
  // We should already have checked whether the object is already registered.
  ASSERT(!has_finalizer(key, lambda));
  auto node = _new FinalizerNode(key, lambda);
  if (node == null) return false;  // Allocation failed.
  _registered_finalizers.append(node);
  return true;
}

bool ObjectHeap::add_vm_finalizer(HeapObject* key) {
  // We should already have checked whether the object is already registered.
  auto node = _new VMFinalizerNode(key);
  if (node == null) return false;  // Allocation failed.
  _registered_vm_finalizers.append(node);
  return true;
}

bool ObjectHeap::remove_finalizer(HeapObject* key) {
  bool found = false;
  _registered_finalizers.remove_wherever([key, &found](FinalizerNode* node) -> bool {
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
  _registered_vm_finalizers.remove_wherever([key, &found](VMFinalizerNode* node) -> bool {
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
  FinalizerNode* node = _runnable_finalizers.remove_first();
  if (node == null) {
    return program()->null_object();
  }

  Object* result = node->lambda();
  delete node;
  return result;
}

#ifdef LEGACY_GC

// We initialize lazily - this is because the number of objects can grow during
// iteration.
ObjectHeap::Iterator::Iterator(BlockList& list, Program* program)
  : _list(list)
  , _iterator(list.end())  // Set to null.
  , _block(null)
  , _current(null)
  , _program(program) {}

bool ObjectHeap::Iterator::eos() {
  return _list.is_empty()
      || (_block == null
          ? _list.first()->is_empty()
          :  (_current >= _block->top() && _block == _list.last()));
}

void ObjectHeap::Iterator::ensure_started() {
  ASSERT(!eos());
  if (_block == null) {
     _iterator = _list.begin();
     _block = *_iterator;
     _current = _block->base();
  }
}

HeapObject* ObjectHeap::Iterator::current() {
  ensure_started();
  if (_current >= _block->top() && _block != _list.last()) {
    _block = *++_iterator;
    _current = _block->base();
  }
  ASSERT(!_block->is_empty());
  return HeapObject::cast(_current);
}

void ObjectHeap::Iterator::advance() {
  ensure_started();

  ASSERT(HeapObject::cast(_current)->header()->is_smi());  // Header is not a forwarding pointer.
  _current = Utils::address_at(_current, HeapObject::cast(_current)->size(_program));
  if (_current >= _block->top() && _block != _list.last()) {
    _block = *++_iterator;
    _current = _block->base();
    ASSERT(!_block->is_empty());
  }
}

#else  // def LEGACY_GC

Usage ObjectHeap::usage(const char* name) {
  return Usage(name, 0, 0);  // TODO: Usage report.
}

#endif  // def LEGACY_GC

ObjectNotifier::ObjectNotifier(Process* process, Object* object)
    : _process(process)
    , _object(object)
    , _message(null) {
  _process->object_heap()->_object_notifiers.prepend(this);
}

ObjectNotifier::~ObjectNotifier() {
  unlink();
  if (_message && _message->clear_object_notifier()) delete _message;
}

void ObjectNotifier::notify() {
  _process->send_mail(_message);
}

void ObjectNotifier::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&_object));
}

}

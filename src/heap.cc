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

Heap::Heap(Process* owner, Program* program, Block* initial_block)
    : RawHeap(owner)
    , _program(program)
    , _in_gc(false)
    , _gc_allowed(true)
    , _total_bytes_allocated(0)
    , _last_allocation_result(ALLOCATION_SUCCESS) {
  if (initial_block == null) return;
  initial_block->_set_process(owner);
  _blocks.append(initial_block);
}

Heap::~Heap() {
  set_writable(true);
  // Deleting a heap is like a scavenge where nothing survives.
  ScavengeScope scope(VM::current()->heap_memory(), this);
  _blocks.free_blocks(this);
}

Instance* Heap::allocate_instance(Smi* class_id) {
  int size = program()->instance_size_for(class_id);
  TypeTag class_tag = program()->class_tag_for(class_id);
  return allocate_instance(class_tag, class_id, Smi::from(size));
}

Instance* Heap::allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size) {
  Instance* result = unvoid_cast<Instance*>(_allocate_raw(instance_size->value()));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(class_id, class_tag);
  return result;
}

Array* Heap::allocate_array(int length, Object* filler) {
  ASSERT(length >= 0);
  ASSERT(length <= Array::max_length());
  HeapObject* result = _allocate_raw(Array::allocation_size(length));
  if (result == null) {
    return null;  // Allocation failure.
  }
  // Initialize object.
  result->_set_header(_program, _program->array_class_id());
  Array::cast(result)->_initialize(length, filler);
  return Array::cast(result);
}

Array* Heap::allocate_array(int length) {
  ASSERT(length >= 0);
  ASSERT(length <= Array::max_length());
  HeapObject* result = _allocate_raw(Array::allocation_size(length));
  if (result == null) {
    return null;  // Allocation failure.
  }
  // Initialize object.
  result->_set_header(_program, _program->array_class_id());
  Array::cast(result)->_initialize(length);
  return Array::cast(result);
}

ByteArray* Heap::allocate_internal_byte_array(int length) {
  ASSERT(length >= 0);
  // Byte array should fit within one heap block.
  ASSERT(length <= ByteArray::max_internal_size());
  ByteArray* result = unvoid_cast<ByteArray*>(_allocate_raw(ByteArray::internal_allocation_size(length)));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->byte_array_class_id());
  result->_initialize(length);
  return result;
}

Double* Heap::allocate_double(double value) {
  HeapObject* result = _allocate_raw(Double::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->double_class_id());
  Double::cast(result)->_initialize(value);
  return Double::cast(result);
}

LargeInteger* Heap::allocate_large_integer(int64 value) {
  HeapObject* result = _allocate_raw(LargeInteger::allocation_size());
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(_program, _program->large_integer_class_id());
  LargeInteger::cast(result)->_initialize(value);
  return LargeInteger::cast(result);
}

int Heap::payload_size() {
  return _blocks.payload_size();
}

String* Heap::allocate_internal_string(int length) {
  ASSERT(length >= 0);
  ASSERT(length <= String::max_internal_size());
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

HeapObject* Heap::_allocate_raw(int byte_size) {
  ASSERT(byte_size > 0);
  ASSERT(byte_size <= Block::max_payload_size());
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

Heap::AllocationResult Heap::_expand() {
  Block* block = VM::current()->heap_memory()->allocate_block(this);
  if (block == null) return ALLOCATION_OUT_OF_MEMORY;
  _blocks.append(block);
  return ALLOCATION_SUCCESS;
}

Heap::AllocationResult ObjectHeap::_expand() {
  word used = (_blocks.length() << TOIT_PAGE_SIZE_LOG2) + _external_memory;
  if (_limit != 0 && used >= _limit) {
#ifdef TOIT_GC_LOGGING
    printf("[gc @ %p%s | soft limit reached (%zd >= %zd)]\n",
        owner(), VM::current()->scheduler()->is_boot_process(owner()) ? "*" : "",
        used, _limit);
#endif
    return ALLOCATION_HIT_LIMIT;
  }
  return Heap::_expand();
}

class ScavengeState : public RootCallback {
 public:
  explicit ScavengeState(Heap* heap)
      : _heap(heap), _scope(VM::current()->heap_memory(), heap) {
    blocks.append(VM::current()->heap_memory()->allocate_block_during_scavenge(heap));
  }

  static bool is_forward_address(Object* object) { return object->is_heap_object(); }

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
      // Shrink stacks to 3x headroom (1x headroom required).
      // TODO(anders): Skip the active Task, or perhaps use different target?
      int target = stack->top() - 3 * Stack::OVERFLOW_HEADROOM;
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
    ASSERT(is_forward_address(from->header_during_gc()));
    return result;
  }

  // Callback defined in RootCallback.
  virtual void do_roots(Object** roots, int length) {
    for (int i = 0; i < length; i++) {
      if (Flags::tracegc && Flags::verbose) printf(" - do root %p\n", &roots[i]);
      Object* content = roots[i];
      if (!content->is_heap_object()) continue;  // Do nothing.
      HeapObject* heap_object = HeapObject::cast(content);
      if (Heap::in_read_only_program_heap(heap_object, _heap)) continue;  // Do nothing, content is outside heap.
      Object* header = HeapObject::cast(content)->header_during_gc();
      roots[i] = is_forward_address(header)          // Check whether there is a forward address.
          ? header                                   // if so, update the root with the forwarding.
          : copy_object(HeapObject::cast(content));  // otherwise, copy the object.
    }
  }

  void process_to_objects(Heap::Iterator& objects) {
    while (!objects.eos()) {
      if (Flags::tracegc && Flags::verbose) printf(" - process object %p\n", objects.current());
      objects.current()->roots_do(_heap->program(), this);
      objects.advance();
    }
  }

  void process_to_space() {
    Heap::Iterator objects(blocks, _heap->program());
    while (!objects.eos()) process_to_objects(objects);
    ASSERT(objects.eos());
  }

  BlockList blocks;
 private:
  Heap* _heap;
  ScavengeScope _scope;
};

String* ProgramHeap::allocate_string(const char* str) {
  return allocate_string(str, strlen(str));
}

String* ProgramHeap::allocate_string(const char* str, int length) {
  bool can_fit_in_heap_block = length <= String::max_internal_size();
  String* result;
  if (can_fit_in_heap_block) {
    result = allocate_internal_string(length);
    // We are in the program heap. We should never run out of memory.
    ASSERT(result != null);
    // Initialize object.
    String::Bytes bytes(result);
    bytes._initialize(str);
  } else {
    result = allocate_external_string(length, const_cast<uint8*>(unsigned_cast(str)), false);
  }
  result->hash_code();  // Ensure hash_code is computed at creation.
  return result;
}

ByteArray* ProgramHeap::allocate_byte_array(const uint8* data, int length) {
  if (length > ByteArray::max_internal_size()) {
    auto result = allocate_external_byte_array(length, const_cast<uint8*>(data), false, false);
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

Object** ObjectHeap::_copy_global_variables() {
  return _program->global_variables.copy();
}

ObjectHeap::ObjectHeap(Program* program, Process* owner, Block* block)
    : Heap(owner, program, block)
    , _max_heap_size(0)
    , _external_memory(0)
    , _hatch_method(Method::invalid())
    , _finalizer_notifier(null)
    , _gc_count(0)
    , _global_variables(null) {
  if (block == null) return;
  _task = allocate_task();
  _global_variables = _copy_global_variables();
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
}

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

void ObjectHeap::register_external_allocation(word size) {
  if (size == 0) return;
  // Overloading on an atomic type makes an atomic += and returns new value.
  _external_memory += _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD + size;
  _total_bytes_allocated += size;
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

int ObjectHeap::payload_size() {
  int base = Heap::payload_size();
  return base + sizeof(Object*) * (program()->global_variables.length());
}

ByteArray* Heap::allocate_external_byte_array(int length, uint8* memory, bool dispose, bool clear_content) {
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

String* Heap::allocate_external_string(int length, uint8* memory, bool dispose) {
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
  ASSERT(owner() == result->owner());
  Task::cast(result)->_initialize(stack, Smi::from(owner()->next_task_id()));
  int instance_size = program()->instance_size_for(result);
  for (int i = Task::ID_INDEX + 1; i < result->length(instance_size); i++) {
    result->at_put(i, program()->null_object());
  }
  stack->set_task(result);
  return result;
}

Stack* ObjectHeap::allocate_stack(int length) {
  int size = Stack::allocation_size(length);
  Stack* result = unvoid_cast<Stack*>(_allocate_raw(size));
  if (result == null) return null;  // Allocation failure.
  // Initialize object.
  result->_set_header(program(), program()->stack_class_id());
  Stack::cast(result)->_initialize(length);
  ASSERT(owner() == result->owner());
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

int ObjectHeap::scavenge() {
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
  ScavengeState ss(this);

  // Process the roots in the object heap.
  ss.do_root(reinterpret_cast<Object**>(&_task));
  ss.do_root(reinterpret_cast<Object**>(&_hatch_arguments));
  ss.do_roots(_global_variables, program()->global_variables.length());
  for (auto root : _external_roots) ss.do_roots(root->slot(), 1);

  // Process roots in the _object_notifiers list.
  for (ObjectNotifier* n : _object_notifiers) n->roots_do(&ss);
  // Process roots in the _runnable_finalizers.
  for (FinalizerNode* node : _runnable_finalizers) {
    node->roots_do(&ss);
  }

  // Process the to space.
  Iterator objects(ss.blocks, program());
  while (!objects.eos()) ss.process_to_objects(objects);

  // Process the registered finalizer list.
  if (!_registered_finalizers.is_empty() && Flags::tracegc && Flags::verbose) printf(" - Processing registered finalizers\n");
  ObjectHeap* heap = this;
  _registered_finalizers.remove_wherever([&ss, heap](FinalizerNode* node) -> bool {
    bool is_alive = ScavengeState::is_forward_address(node->key()->header_during_gc());
    if (!is_alive) {
      // Clear the key so it is not retained.
      node->set_key(heap->program()->null_object());
    }
    node->roots_do(&ss);
    if (is_alive && Flags::tracegc && Flags::verbose) printf(" - Finalizer %p is alive\n", node);
    if (is_alive) return false;  // Keep node in list.
    // From here down, the node is going to be unlinked by returning true.
    if (Flags::tracegc && Flags::verbose) printf(" - Finalizer %p is unreachable\n", node);
    heap->_runnable_finalizers.append(node);
    // Signal finalizers are ready to run.
    if (heap->_finalizer_notifier != null) {
      heap->_finalizer_notifier->notify();
    }
    return true; // Remove node from list.
  });

  // Process the finalizers in the to space.
  while (!objects.eos()) ss.process_to_objects(objects);
  ASSERT(objects.eos());

  // Process registered VM finalizers.
  _registered_vm_finalizers.remove_wherever([&ss, this](VMFinalizerNode* node) -> bool {
    bool is_alive = ScavengeState::is_forward_address(node->key()->header_during_gc());

    if (is_alive && Flags::tracegc && Flags::verbose) printf(" - Finalizer %p is alive\n", node);
    if (is_alive) {
      node->roots_do(&ss);
      return false; // Keep node in list.
    }
    if (Flags::tracegc && Flags::verbose) printf(" - Processing registered finalizer %p for external memory.\n", node);
    node->free_external_memory(owner());
    delete node;
    return true; // Remove node from list.
  });

  // Complete the scavenge.
  while (!objects.eos()) ss.process_to_objects(objects);
  ASSERT(objects.eos());

  take_blocks(&ss.blocks);
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
      owner(), VM::current()->scheduler()->is_boot_process(owner()) ? "*" : "",
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
      owner(), VM::current()->scheduler()->is_boot_process(owner()) ? "*" : "",
      FORMAT(external_memory_before), FORMAT(toit_before),                           // objects-before
      FORMAT(_external_memory), FORMAT(toit_after),                                  // objects-after
      static_cast<int>(microseconds / 1000), static_cast<int>(microseconds % 1000)); // time
#endif // TOIT_FREERTOS
#endif // TOIT_GC_LOGGING
  return blocks_before - blocks_after;
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

void ObjectHeap::set_finalizer_notifier(ObjectNotifier* notifier) {
  ASSERT(_finalizer_notifier == null);
  _finalizer_notifier = notifier;

  if (!_runnable_finalizers.is_empty()) {
    notifier->notify();
  }
}

void FinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&_key));
  cb->do_root(reinterpret_cast<Object**>(&_lambda));
}

void VMFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&_key));
}

void VMFinalizerNode::free_external_memory(Process* process) {
  uint8* memory = null;
  word accounting_size = 0;
  if (key()->is_byte_array()) {
    ByteArray* byte_array = ByteArray::cast(key());
    if (byte_array->external_tag() == MappedFileTag) return;  // TODO(Lau): release mapped file, so flash storage can be reclaimed.
    ASSERT(byte_array->has_external_address());
    ByteArray::Bytes bytes(byte_array);
    memory = bytes.address();
    accounting_size = bytes.length();
    // Accounting size is 0 if the byte array is tagged, since we don't account
    // memory for Resources etc.
    ASSERT(byte_array->external_tag() == RawByteTag || byte_array->external_tag() == NullStructTag);
  } else if (key()->is_string()) {
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


// We initialize lazily - this is because the number of objects can grow during
// iteration.
Heap::Iterator::Iterator(BlockList& list, Program* program)
  : _list(list)
  , _iterator(list.end())  // Set to null.
  , _block(null)
  , _current(null)
  , _program(program) {}

bool Heap::Iterator::eos() {
  return _list.is_empty()
      || (_block == null
          ? _list.first()->is_empty()
          :  (_current >= _block->top() && _block == _list.last()));
}

void Heap::Iterator::ensure_started() {
  ASSERT(!eos());
  if (_block == null) {
     _iterator = _list.begin();
     _block = *_iterator;
     _current = _block->base();
  }
}

HeapObject* Heap::Iterator::current() {
  ensure_started();
  if (_current >= _block->top() && _block != _list.last()) {
    _block = *++_iterator;
    _current = _block->base();
  }
  ASSERT(!_block->is_empty());
  return HeapObject::cast(_current);
}

void Heap::Iterator::advance() {
  ensure_started();

  ASSERT(HeapObject::cast(_current)->header()->is_smi());  // Header is not a forwarding pointer.
  _current = Utils::address_at(_current, HeapObject::cast(_current)->size(_program));
  if (_current >= _block->top() && _block != _list.last()) {
    _block = *++_iterator;
    _current = _block->base();
    ASSERT(!_block->is_empty());
  }
}

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

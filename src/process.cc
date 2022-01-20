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

#include "entropy_mixer.h"
#include "heap.h"
#include "heap_report.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "os.h"
#include "process.h"
#include "process_group.h"
#include "resource.h"
#include "scheduler.h"
#include "vm.h"

namespace toit {

void ProcessRunner::start() {
  ASSERT(_process == null);
  _process = _vm->scheduler()->run_external(this);
}

bool ProcessRunner::send(int pid, int type, void* data, int length) {
  SystemMessage* message = _new SystemMessage(type, _process->group()->id(), _process->id(),
      unvoid_cast<uint8*>(data), length);
  if (message == null) {
    free(data);  // <--- TODO(kasper): Come up with some reasonable semantics around this.
    return false;
  }
  scheduler_err_t result = _vm->scheduler()->send_message(pid, message);
  if (result == MESSAGE_OK) return true;
  delete message;
  return false;
}

Interpreter::Result ProcessRunner::run() {
  while (true) {
    Message* message = next();
    if (message == null) {
      return Interpreter::Result(Interpreter::Result::YIELDED);
    }
    if (message->is_system()) {
      on_message(static_cast<SystemMessage*>(message));
    }
    advance();
  }
}

Message* ProcessRunner::next() const {
  return _process->peek_message();
}

void ProcessRunner::advance() {
  _process->remove_first_message();
}

const char* Process::StateName[] = {
  "IDLE",
  "SCHEDULED",
  "RUNNING",
};

Process::Process(Program* program, ProcessRunner* runner, ProcessGroup* group, Block* initial_block)
    : _id(VM::current()->scheduler()->next_process_id())
    , _next_task_id(0)
    , _program(program)
    , _runner(runner)
    , _group(group)
    , _entry(Method::invalid())
    , _object_heap(program, this, initial_block)
    , _memory_usage(Usage("initial object heap"))
    , _last_bytes_allocated(0)
    , _random_seeded(false)
    , _random_state0(1)
    , _random_state1(2)
    , _current_directory(-1)
    , _signals(0)
    , _state(IDLE)
    , _scheduler_thread(null) {
  // Link this process to the program heap.
  _group->add(this);
  ASSERT(_group->lookup(_id) == this);
}

Process::Process(Program* program, ProcessGroup* group, char** args, Block* initial_block)
   : Process(program, null, group, initial_block) {
  _entry = program->entry();
  _args = args;
  _object_heap.set_hatch_method(Method::invalid());
  _object_heap.set_hatch_arguments(program->null_object());
}

#ifndef TOIT_FREERTOS
Process::Process(Program* program, ProcessGroup* group, SnapshotBundle bundle, char** args, Block* initial_block)
  : Process(program, null, group, initial_block) {
  _entry = program->entry();
  _args = args;
  ByteArray* snap = _object_heap.allocate_external_byte_array(bundle.size(), bundle.buffer(), true, false);
  _object_heap.register_external_allocation(bundle.size());

  // We don't run from snapshot on the device so we can assume that allocation
  // does not fail on a newly created heap.
  ASSERT(snap != null);
  _object_heap.set_hatch_arguments(snap);
}
#endif

Process::Process(Program* program, ProcessGroup* group, Method method, const uint8* arguments_address, int arguments_length, Block* initial_block)
   : Process(program, null, group, initial_block) {
  _entry = program->hatch_entry();
  _args = null;
  ByteArray* args = _object_heap.allocate_internal_byte_array(arguments_length);
  // We don't run from snapshot on the device so we can assume that allocation
  // does not fail on a newly created heap.
#ifdef TOIT_FREERTOS
  UNREACHABLE();
#else
  ASSERT(args != null);
#endif
  ByteArray::Bytes to(args);

  memcpy(to.address(), arguments_address, to.length());

  _object_heap.set_hatch_method(method);
  _object_heap.set_hatch_arguments(args);
}

Process::Process(ProcessRunner* runner, ProcessGroup* group) : Process(null, runner, group, null) {
}

Process::~Process() {
  // Clean up unclaimed resource groups.
  while (ResourceGroup* r = _resource_groups.first()) {
    r->tear_down();  // Also removes from linked list.
  }
  if (_current_directory >= 0) {
    OS::close(_current_directory);
  }

  // Use [has_message] to ensure that system_acks are processed and message
  // budget is returned.
  while (has_messages()) {
    remove_first_message();
  }
}

String* Process::allocate_string(const char* content, int length, Error** error) {
  String* result = allocate_string(length, error);
  if (result == null) return result;  // Allocation failure.
  // Initialize object.
  String::Bytes bytes(result);
  bytes._initialize(content);
  return result;
}

String* Process::allocate_string(int length, Error** error) {
  ASSERT(length >= 0);
  bool can_fit_in_heap_block = length <= String::max_internal_size();
  if (can_fit_in_heap_block) {
    String* result = object_heap()->allocate_internal_string(length);
    if (result != null) return result;
#ifdef TOIT_GC_LOGGING
    printf("[gc @ %p%s | string allocation failed, length = %d (heap)]\n",
        this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
        length);
#endif
    *error = Error::from(program()->allocation_failed());
    return null;
  }

  AllocationManager allocation(this);
  uint8* memory;
  {
    HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_STRING_MALLOC_TAG);
    memory = allocation.alloc(length + 1);
  }
  if (memory == null) {
#ifdef TOIT_GC_LOGGING
      printf("[gc @ %p%s | string allocation failed, length = %d (malloc)]\n",
          this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
          length);
#endif
    *error = Error::from(program()->allocation_failed());
    return null;
  }
  memory[length] = '\0';  // External strings should be zero-terminated.
  String* result = object_heap()->allocate_external_string(length, memory, true);
  if (result != null) {
    allocation.keep_result();
    return result;
  }
#ifdef TOIT_GC_LOGGING
    printf("[gc @ %p%s | string allocation failed, length = %d (after malloc)]\n",
        this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
        length);
#endif
    *error = Error::from(program()->allocation_failed());
    return null;
}

Object* Process::allocate_string_or_error(const char* content, int length) {
  Error* error = null;
  String* result = allocate_string(content, length, &error);
  if (result == null) return error;
  return result;
}

String* Process::allocate_string(const char* content, Error** error) {
  return allocate_string(content, strlen(content), error);
}

Object* Process::allocate_string_or_error(const char* content) {
  return allocate_string_or_error(content, strlen(content));
}

ByteArray* Process::allocate_byte_array(int length, Error** error, bool force_external) {
  ASSERT(length >= 0);
  if (force_external || length > ByteArray::max_internal_size()) {
    // Byte array cannot fit within a heap block so place content in malloced space.
    AllocationManager allocation(this);
    uint8* memory;
    {
      HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
      memory = allocation.alloc(length);
    }
    if (memory == null) {
      // Malloc failed, report it.
#ifdef TOIT_GC_LOGGING
      printf("[gc @ %p%s | byte array allocation failed, length = %d (malloc)]\n",
          this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
          length);
#endif
      *error = Error::from(program()->allocation_failed());
      return null;
    }
    if (ByteArray* result = object_heap()->allocate_external_byte_array(length, memory, true)) {
      allocation.keep_result();
      return result;
    }
#ifdef TOIT_GC_LOGGING
    printf("[gc @ %p%s | byte array allocation failed, length = %d (after malloc)]\n",
        this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
        length);
#endif
    *error = Error::from(program()->allocation_failed());
    return null;
  }
  if (ByteArray* result = object_heap()->allocate_internal_byte_array(length)) return result;
#ifdef TOIT_GC_LOGGING
  printf("[gc @ %p%s | byte array allocation failed, length = %d (heap)]\n",
      this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
      length);
#endif
  *error = Error::from(program()->allocation_failed());
  return null;
}

void Process::_append_message(Message* message) {
  Locker locker(OS::scheduler_mutex());  // Fix this
  if (message->is_object_notify()) {
    ObjectNotifyMessage* obj_notify = static_cast<ObjectNotifyMessage*>(message);
    if (obj_notify->is_queued()) return;
    obj_notify->mark_queued();
  }
  _messages.append(message);
}

bool Process::has_messages() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  return !_messages.is_empty();
}

Message* Process::peek_message() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  return _messages.first();
}

void Process::remove_first_message() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  ASSERT(!_messages.is_empty());
  Message* message = _messages.remove_first();
  if (message->is_object_notify()) {
    if (!static_cast<ObjectNotifyMessage*>(message)->mark_dequeued()) return;
  }
  delete message;
}

int Process::message_count() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  int count = 0;
  for (MessageFIFO::Iterator it = _messages.begin(); it != _messages.end(); ++it) {
    count++;
  }
  return count;
}

void Process::send_mail(Message* message) {
  _append_message(message);
  VM::current()->scheduler()->process_ready(this);
}

void Process::_ensure_random_seeded() {
  if (_random_seeded) return;
  uint8 seed[16];
  VM::current()->entropy_mixer()->get_entropy(seed, sizeof(seed));
  random_seed(seed, sizeof(seed));
  _random_seeded = true;
}

uint64_t Process::random() {
  _ensure_random_seeded();
  // xorshift128+.
  uint64_t s1 = _random_state0;
  uint64_t s0 = _random_state1;
  _random_state0 = s0;
  s1 ^= s1 << 23;
  s1 ^= s1 >> 18;
  s1 ^= s0;
  s1 ^= s0 >> 5;
  _random_state1 = s1;
  return _random_state0 + _random_state1;
}

void Process::random_seed(const uint8* buffer, size_t size) {
  _random_state0 = 0xdefa17;
  _random_state1 = 0xf00baa;
  memcpy(&_random_state0, buffer, Utils::min(size, sizeof(_random_state0)));
  if (size >= sizeof(_random_state0)) {
    buffer += sizeof(_random_state0);
    size -= sizeof(_random_state0);
    memcpy(&_random_state1, buffer, Utils::min(size, sizeof(_random_state1)));
  }
  _random_seeded = true;
}

void Process::add_resource_group(ResourceGroup* r) {
  _resource_groups.prepend(r);
}

void Process::remove_resource_group(ResourceGroup* group) {
  ResourceGroup* g = _resource_groups.remove(group);
  ASSERT(g == group);
}

void Process::signal(Signal signal) {
  _signals |= signal;
  SchedulerThread* s = _scheduler_thread;
  if (s != null) s->interpreter()->preempt();
}

void Process::clear_signal(Signal signal) {
  _signals &= ~signal;
}

void Process::print() {
  printf("Process #%d\n", _id);
  Usage u = object_heap()->usage("heap");
  ProgramUsage p = program()->usage();
  u.print(2);
  p.print(2);
}

}

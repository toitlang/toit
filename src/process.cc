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

const char* Process::StateName[] = {
  "IDLE",
  "SCHEDULED",
  "RUNNING",
};

Process::Process(Program* program, ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination, Chunk* initial_chunk)
    : id_(VM::current()->scheduler()->next_process_id())
    , next_task_id_(0)
    , program_(program)
    , runner_(runner)
    , group_(group)
    , program_heap_address_(program ? program->program_heap_address_ : 0)
    , program_heap_size_(program ? program->program_heap_size_ : 0)
    , entry_(Method::invalid())
    , spawn_method_(Method::invalid())
    , object_heap_(program, this, initial_chunk)
    , last_bytes_allocated_(0)
    , termination_message_(termination)
    , random_seeded_(false)
    , random_state0_(1)
    , random_state1_(2)
    , current_directory_(-1)
    , signals_(0)
    , state_(IDLE)
    , scheduler_thread_(null) {
  // We can't start a process from a heap that has not been linearly allocated
  // because we use the address range to distinguish program pointers and
  // process pointers.
  ASSERT(!program || program_heap_size_ > 0);
  // Link this process to the program heap.
  group_->add(this);
  ASSERT(group_->lookup(id_) == this);
}

Process::Process(Program* program, ProcessGroup* group, SystemMessage* termination, Chunk* initial_chunk)
    : Process(program, null, group, termination, initial_chunk) {
  entry_ = program->entry_main();
}

Process::Process(Program* program, ProcessGroup* group, SystemMessage* termination, Method method, Chunk* initial_chunk)
    : Process(program, null, group, termination, initial_chunk) {
  entry_ = program->entry_spawn();
  spawn_method_ = method;
}

Process::Process(ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination)
    : Process(null, runner, group, termination, null) {}

Process::~Process() {
  state_ = TERMINATING;
  MessageDecoder::deallocate(spawn_arguments_);
  delete termination_message_;

  // Clean up unclaimed resource groups.
  while (ResourceGroup* r = resource_groups_.first()) {
    r->tear_down();  // Also removes from linked list.
  }

  if (current_directory_ >= 0) {
    OS::close(current_directory_);
  }

  // Use [has_message] to ensure that system_acks are processed and message
  // budget is returned.
  while (has_messages()) {
    remove_first_message();
  }
}

void Process::set_main_arguments(uint8* arguments) {
  ASSERT(main_arguments_ == null);
  main_arguments_ = arguments;
}

void Process::set_spawn_arguments(uint8* arguments) {
  ASSERT(spawn_arguments_ == null);
  spawn_arguments_ = arguments;
}

#ifndef TOIT_FREERTOS
void Process::set_main_arguments(char** argv) {
  ASSERT(main_arguments_ == null);
  int argc = 0;
  if (argv) {
    while (argv[argc] != null) argc++;
  }

  int size;
  { MessageEncoder encoder(null);
    encoder.encode_arguments(argv, argc);
    size = encoder.size();
  }

  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  ASSERT(buffer != null)
  MessageEncoder encoder(buffer);
  encoder.encode_arguments(argv, argc);
  main_arguments_ = buffer;
}

void Process::set_spawn_arguments(SnapshotBundle system, SnapshotBundle application) {
  ASSERT(spawn_arguments_ == null);
  int size;
  { MessageEncoder encoder(null);
    encoder.encode_bundles(system, application);
    size = encoder.size();
  }

  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  ASSERT(buffer != null)
  MessageEncoder encoder(buffer);
  encoder.encode_bundles(system, application);
  spawn_arguments_ = buffer;
}
#endif

SystemMessage* Process::take_termination_message(uint8 result) {
  SystemMessage* message = termination_message_;
  termination_message_ = null;
  message->set_pid(id());

  // Encode the exit value as small integer in the termination message.
  MessageEncoder::encode_process_message(message->data(), result);

  return message;
}


String* Process::allocate_string(const char* content, int length) {
  String* result = allocate_string(length);
  if (result == null) return result;  // Allocation failure.
  // Initialize object.
  String::Bytes bytes(result);
  bytes._initialize(content);
  return result;
}

String* Process::allocate_string(int length) {
  ASSERT(length >= 0);
  bool can_fit_in_heap_block = length <= String::max_internal_size_in_process();
  if (can_fit_in_heap_block) {
    String* result = object_heap()->allocate_internal_string(length);
    if (result != null) return result;
#ifdef TOIT_GC_LOGGING
    printf("[gc @ %p%s | string allocation failed, length = %d (heap)]\n",
        this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
        length);
#endif
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
    return null;
}

Object* Process::allocate_string_or_error(const char* content) {
  return allocate_string_or_error(content, strlen(content));
}

Object* Process::allocate_string_or_error(const char* content, int length) {
  String* result = allocate_string(content, length);
  if (result == null) return Error::from(program()->allocation_failed());
  return result;
}

String* Process::allocate_string(const char* content) {
  return allocate_string(content, strlen(content));
}

ByteArray* Process::allocate_byte_array(int length, bool force_external) {
  ASSERT(length >= 0);
  if (force_external || length > ByteArray::max_internal_size_in_process()) {
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
    return null;
  }
  if (ByteArray* result = object_heap()->allocate_internal_byte_array(length)) return result;
#ifdef TOIT_GC_LOGGING
  printf("[gc @ %p%s | byte array allocation failed, length = %d (heap)]\n",
      this, VM::current()->scheduler()->is_boot_process(this) ? "*" : " ",
      length);
#endif
  return null;
}

void Process::_append_message(Message* message) {
  Locker locker(OS::scheduler_mutex());  // Fix this
  if (message->is_object_notify()) {
    ObjectNotifyMessage* obj_notify = static_cast<ObjectNotifyMessage*>(message);
    if (obj_notify->is_queued()) return;
    obj_notify->mark_queued();
  }
  messages_.append(message);
}

bool Process::has_messages() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  return !messages_.is_empty();
}

Message* Process::peek_message() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  return messages_.first();
}

void Process::remove_first_message() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  ASSERT(!messages_.is_empty());
  Message* message = messages_.remove_first();
  if (message->is_object_notify()) {
    if (!static_cast<ObjectNotifyMessage*>(message)->mark_dequeued()) return;
  }
  delete message;
}

int Process::message_count() {
  Locker locker(OS::scheduler_mutex());  // Fix this
  int count = 0;
  for (MessageFIFO::Iterator it = messages_.begin(); it != messages_.end(); ++it) {
    count++;
  }
  return count;
}

void Process::_ensure_random_seeded() {
  if (random_seeded_) return;
  uint8 seed[16];
  EntropyMixer::instance()->get_entropy(seed, sizeof(seed));
  random_seed(seed, sizeof(seed));
  random_seeded_ = true;
}

uint64_t Process::random() {
  _ensure_random_seeded();
  // xorshift128+.
  uint64_t s1 = random_state0_;
  uint64_t s0 = random_state1_;
  random_state0_ = s0;
  s1 ^= s1 << 23;
  s1 ^= s1 >> 18;
  s1 ^= s0;
  s1 ^= s0 >> 5;
  random_state1_ = s1;
  return random_state0_ + random_state1_;
}

void Process::random_seed(const uint8* buffer, size_t size) {
  random_state0_ = 0xdefa17;
  random_state1_ = 0xf00baa;
  memcpy(&random_state0_, buffer, Utils::min(size, sizeof(random_state0_)));
  if (size >= sizeof(random_state0_)) {
    buffer += sizeof(random_state0_);
    size -= sizeof(random_state0_);
    memcpy(&random_state1_, buffer, Utils::min(size, sizeof(random_state1_)));
  }
  random_seeded_ = true;
}

void Process::add_resource_group(ResourceGroup* r) {
  resource_groups_.prepend(r);
}

void Process::remove_resource_group(ResourceGroup* group) {
  ResourceGroup* g = resource_groups_.remove(group);
  ASSERT(g == group);
}

void Process::signal(Signal signal) {
  signals_ |= signal;
  SchedulerThread* s = scheduler_thread_;
  if (s != null) s->interpreter()->preempt();
}

void Process::clear_signal(Signal signal) {
  signals_ &= ~signal;
}

uint8 Process::update_priority() {
  uint8 priority = target_priority_;
  priority_ = priority;
  return priority;
}

}

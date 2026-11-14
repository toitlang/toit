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

#include "process_group.h"

#include "objects_inline.h"
#include "os.h"
#include "process.h"
#include "scheduler.h"
#include "vm.h"

namespace toit {

ProcessGroup::ProcessGroup(int id, Program* program, AlignedMemoryBase* memory, const PrimitivePolicy* policy)
    : id_(id)
    , program_(program)
    , memory_(memory)
    , policy_(policy) {}

ProcessGroup::~ProcessGroup() {
  delete method_entries_;
  delete memory_;
  free(grants_);
  PrimitivePolicy::release(policy_);
}

ProcessGroup* ProcessGroup::create(int id, Program* program, AlignedMemoryBase* memory,
                                   const PrimitivePolicy* policy) {
  ASSERT(policy != null);
  MethodEntryTable* entries = null;
  if (program != null) {
    entries = MethodEntryTable::compute(program);
    if (entries == null) {
      PrimitivePolicy::release(policy);
      return null;
    }
  }
  ProcessGroup* result = _new ProcessGroup(id, program, memory, policy);
  if (result == null) {
    delete entries;
    PrimitivePolicy::release(policy);
    return null;
  }
  result->method_entries_ = entries;
  return result;
}

bool ProcessGroup::may_send_to(int pid) const {
  ASSERT(VM::current()->scheduler()->is_locked());
  for (word i = 0; i < grants_count_; i++) {
    if (grants_[i] == pid) return true;
  }
  return false;
}

bool ProcessGroup::grant_send_to(int pid) {
  ASSERT(VM::current()->scheduler()->is_locked());
  if (may_send_to(pid)) return true;
  word capacity = policy_->quotas().max_send_grants;
  // Evicting an older grant would silently break a capability the group
  // is using, so a full set refuses new grants.
  if (grants_count_ >= capacity) return false;
  if (grants_ == null) {
    grants_ = unvoid_cast<int*>(malloc(capacity * sizeof(int)));
    if (grants_ == null) return false;
  }
  grants_[grants_count_++] = pid;
  return true;
}

word ProcessGroup::process_count() {
  ASSERT(VM::current()->scheduler()->is_locked());
  word count = 0;
  for (auto process : processes_) {
    USE(process);
    count++;
  }
  return count;
}

Process* ProcessGroup::lookup(int process_id) {
  ASSERT(VM::current()->scheduler()->is_locked());
  for (auto process : processes_) {
    if (process->id() == process_id) return process;
  }
  return null;
}

void ProcessGroup::add(Process* process) {
  ASSERT(VM::current()->scheduler()->is_locked());
  processes_.prepend(process);
}

bool ProcessGroup::remove(Process* process) {
  ASSERT(VM::current()->scheduler()->is_locked());
  Process* p = processes_.remove(process);
  if (p != process) {
    FATAL("Process not in list");
  }
  return !processes_.is_empty();
}

} // namespace toit

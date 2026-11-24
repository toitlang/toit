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
#include "interpreter_v2.h"
#include "verifier_v2.h"
#include "verifier.h"
#include "scheduler.h"
#include "vm.h"

namespace toit {

ProcessGroup::ProcessGroup(int id, Program* program, AlignedMemoryBase* memory, const PrimitivePolicy* policy)
    : id_(id)
    , program_(program)
    , memory_(memory)
    , policy_(policy) {}

ProcessGroup::~ProcessGroup() {
#ifndef TOIT_NO_CXX_INTERPRETER
  delete method_entries_;
#endif
  delete v2_methods_;
  delete memory_;
  free(grants_);
  PrimitivePolicy::release(policy_);
}

ProcessGroup* ProcessGroup::create(int id, Program* program, AlignedMemoryBase* memory,
                                   const PrimitivePolicy* policy, V2MethodTable* v2_methods) {
  ASSERT(policy != null);
  if (program != null && !InitialMemoryManager::can_allocate_task(program)) {
    delete v2_methods;
    PrimitivePolicy::release(policy);
    return null;
  }
  // A primitive's failure is retried after a GC exactly when its error root
  // is one of the out-of-memory roots, so the error roots must be distinct
  // heap references (the C++ proofs of the retry rule rely on it: the
  // `process` predicate of verified/cxx/annotated/model).
  if (program != null && !program->has_valid_error_roots()) {
    fprintf(stderr, "program refused: its error roots are not distinct heap references\n");
    delete v2_methods;
    PrimitivePolicy::release(policy);
    return null;
  }
  MethodEntryTable* entries = null;
  if (program != null && program->is_format2()) {
    if (v2_methods == null) {
      v2_methods = V2MethodTable::compute(program);
      // An untrusted program never runs unverified: launches verify the
      // table they pass in; any other way here verifies now. With
      // -Xverify / TOIT_VERIFY a trusted program is verified (trusted
      // rules) on the table it runs, so that it runs on the verified loop.
      // Debug builds verify trusted programs too, as a check on the
      // compiler (V2MethodTable::verify_trusted_by_default).
      bool untrusted = policy->is_untrusted();
      if (v2_methods != null
          && (untrusted || Verifier::is_enabled() || V2MethodTable::verify_trusted_by_default())
          && !V2Verifier::verify(program, v2_methods, !untrusted)) {
        delete v2_methods;
        v2_methods = null;
      }
    }
    if (v2_methods == null) {
      PrimitivePolicy::release(policy);
      return null;
    }
    // Without the core's checked loop (devices) a format-2 program runs
    // only on the verified loop: untrusted programs if the verifier
    // accepted them, trusted ones always (V2MethodTable::trusted_on_verified_loop).
    if (!V2MethodTable::checked_loop_linked()
        && !v2_methods->runs_verified(policy->is_untrusted())
        && (policy->is_untrusted() || !V2MethodTable::trusted_on_verified_loop())) {
      fprintf(stderr, "format-2 program refused: not verified (this VM has no checked loop)\n");
      delete v2_methods;
      PrimitivePolicy::release(policy);
      return null;
    }
  } else if (program != null) {
    ASSERT(v2_methods == null);
#ifdef TOIT_NO_CXX_INTERPRETER
    // No C++ interpreter (CMake TOIT_CXX_INTERPRETER=OFF): format 2 only.
    fprintf(stderr, "format-1 program refused: this VM runs only format 2\n");
    PrimitivePolicy::release(policy);
    return null;
#else
    entries = MethodEntryTable::compute(program);
    if (entries == null) {
      PrimitivePolicy::release(policy);
      return null;
    }
#endif
  }
  ProcessGroup* result = _new ProcessGroup(id, program, memory, policy);
  if (result == null) {
#ifndef TOIT_NO_CXX_INTERPRETER
    delete entries;
#endif
    delete v2_methods;
    PrimitivePolicy::release(policy);
    return null;
  }
  result->method_entries_ = entries;
  result->v2_methods_ = v2_methods;
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

void ProcessGroup::begin_process_teardown(Process* process) {
  ASSERT(VM::current()->scheduler()->is_locked());
  Process* p = processes_.remove(process);
  if (p != process) {
    FATAL("Process not in list");
  }
  ++pending_teardowns_;
}

bool ProcessGroup::finish_process_teardown() {
  ASSERT(VM::current()->scheduler()->is_locked());
  ASSERT(pending_teardowns_ != 0);
  --pending_teardowns_;
  return pending_teardowns_ == 0 && processes_.is_empty();
}

} // namespace toit

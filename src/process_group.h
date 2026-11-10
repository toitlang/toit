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

#pragma once

#include "linked.h"
#include "method_entries.h"
#include "primitive_policy.h"
#include "process.h"
#include "top.h"

namespace toit {

class ProcessGroup;

// The scheduler has a linked list of groups, manipulated under the
// scheduler lock.
typedef DoubleLinkedList<ProcessGroup> ProcessGroupList;

class ProcessGroup : public ProcessGroupList::Element {
 public:
  ~ProcessGroup();

  // Creates a process group with the given policy. If the policy is owned
  // (see PrimitivePolicy::is_owned) the group takes it over, also when the
  // creation fails.
  static ProcessGroup* create(int id, Program* program, AlignedMemoryBase* memory = null,
                              const PrimitivePolicy* policy = PrimitivePolicy::trusted());

  int id() const { return id_; }
  Program* program() const { return program_; }

  // The policy of the group. It is immutable and shared by all processes in
  // the group, including the ones spawned from inside the group.
  const PrimitivePolicy* policy() const { return policy_; }

  // The allowed-target set: process ids that processes of a group with a
  // messaging-restricted policy may send to, in addition to the system
  // process and their own group. Grants are issued by the system process
  // (service discovery) and by the scheduler when a process of this group
  // receives an RPC request (so it can reply). Must be called with the
  // scheduler lock held.
  bool may_send_to(int pid) const;
  void grant_send_to(int pid);

  // The number of processes in the group. Must be called with the scheduler
  // lock held.
  word process_count();

  // The legal method entries of the program (null if there is no program).
  const MethodEntryTable* method_entries() const { return method_entries_; }

  Process* lookup(int process_id);
  void add(Process* process);

  // Remove the given process from this group. Returns true
  // if there are more processes left in the group.
  bool remove(Process* process);

  ProcessListFromProcessGroup& processes() { return processes_; }

 private:
  const int id_;
  Program* const program_;

  // If the process groups owns memory, it is automatically deleted
  // when the process group goes away.
  AlignedMemoryBase* const memory_;

  MethodEntryTable* method_entries_ = null;

  ProcessListFromProcessGroup processes_;

  const PrimitivePolicy* const policy_;

  // Ring buffer of granted target pids. Allocated on the first grant.
  int* grants_ = null;
  word grants_count_ = 0;
  word grants_next_ = 0;

  ProcessGroup(int id, Program* program, AlignedMemoryBase* memory, const PrimitivePolicy* policy);

  friend class Scheduler;
};

} // namespace toit

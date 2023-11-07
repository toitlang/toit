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

  static ProcessGroup* create(int id, Program* program, AlignedMemoryBase* memory = null);

  int id() const { return id_; }
  Program* program() const { return program_; }

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

  ProcessListFromProcessGroup processes_;

  ProcessGroup(int id, Program* program, AlignedMemoryBase* memory);

  friend class Scheduler;
};

} // namespace toit

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

  static ProcessGroup* create(int id);

  SystemMessage* take_termination_message(int pid, uint8 result);

  int id() const { return _id; }
  Program* program() const;

  Process* lookup(int process_id);
  void add(Process* process);

  // Remove the given process from this group. Returns true
  // if there are more processes left in the group.
  bool remove(Process* process);

  word largest_number_of_blocks_in_a_process();

  ProcessListFromProcessGroup& processes() { return _processes; }

 private:
  const int _id;
  SystemMessage* _termination_message;

  ProcessListFromProcessGroup _processes;

  ProcessGroup(int id, SystemMessage* termination_message);

  friend class Scheduler;
};

} // namespace toit

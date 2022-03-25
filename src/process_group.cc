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

ProcessGroup::ProcessGroup(int id, Program* program, AlignedMemoryBase* memory)
    : _id(id)
    , _program(program)
    , _memory(memory) {
}

ProcessGroup::~ProcessGroup() {
  delete _memory;
}

ProcessGroup* ProcessGroup::create(int id, Program* program, AlignedMemoryBase* memory) {
  return _new ProcessGroup(id, program, memory);
}

Process* ProcessGroup::lookup(int process_id) {
  ASSERT(VM::current()->scheduler()->is_locked());
  for (auto process : _processes) {
    if (process->id() == process_id) return process;
  }
  return null;
}

#ifdef LEGACY_GC
word ProcessGroup::largest_number_of_blocks_in_a_process() {
  ASSERT(VM::current()->scheduler()->is_locked());
  word largest = 0;
  for (auto process : _processes) {
    largest = Utils::max(largest, process->number_of_blocks());
  }
  return largest;
}
#endif

void ProcessGroup::add(Process* process) {
  ASSERT(VM::current()->scheduler()->is_locked());
  _processes.prepend(process);
}

bool ProcessGroup::remove(Process* process) {
  ASSERT(VM::current()->scheduler()->is_locked());
  Process* p = _processes.remove(process);
  if (p != process) {
    FATAL("Process not in list");
  }
  return !_processes.is_empty();
}

} // namespace toit

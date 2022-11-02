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
    : id_(id)
    , program_(program)
    , memory_(memory) {
}

ProcessGroup::~ProcessGroup() {
  delete memory_;
}

ProcessGroup* ProcessGroup::create(int id, Program* program, AlignedMemoryBase* memory) {
  return _new ProcessGroup(id, program, memory);
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

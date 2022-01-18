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

ProcessGroup::ProcessGroup(int id, SystemMessage* termination_message)
  : _id(id)
  , _termination_message(termination_message) {
}

ProcessGroup::~ProcessGroup() {
  free(_termination_message);
}

SystemMessage* ProcessGroup::take_termination_message(int pid, uint8 result) {
  SystemMessage* message = _termination_message;
  _termination_message = null;
  message->set_pid(pid);

  // Encode the exit value as small integer in the termination message.
  MessageEncoder::encode_termination_message(message->data(), result);

  return message;
}

ProcessGroup* ProcessGroup::create(int id) {
  uint8_t* data = unvoid_cast<uint8*>(malloc(MESSAGING_TERMINATION_MESSAGE_SIZE));
  if (data == NULL) return NULL;

  SystemMessage* termination_message = _new SystemMessage(SystemMessage::TERMINATED, id, -1, data, 2);
  if (termination_message == NULL) {
    free(data);
    return NULL;
  }

  ProcessGroup* group = _new ProcessGroup(id, termination_message);
  if (group == NULL) {
    delete termination_message;  // data is freed by ProcessGroup destructor.
    return NULL;
  }
  return group;
}

Program* ProcessGroup::program() const {
  ASSERT(VM::current()->scheduler()->is_locked());
  Process* process = _processes.first();
  return process ? process->program() : null;
}

Process* ProcessGroup::lookup(int process_id) {
  ASSERT(VM::current()->scheduler()->is_locked());
  for (auto process : _processes) {
    if (process->id() == process_id) return process;
  }
  return null;
}

word ProcessGroup::largest_number_of_blocks_in_a_process() {
  ASSERT(VM::current()->scheduler()->is_locked());
  word largest = 0;
  for (auto process : _processes) {
    largest = Utils::max(largest, process->number_of_blocks());
  }
  return largest;
}

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

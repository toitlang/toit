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

#include <signal.h>

#include "entropy_mixer.h"
#include "memory.h"
#include "program_memory.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "resource.h"
#include "scheduler.h"
#include "vm.h"

namespace toit {

class NopEventSource : public EventSource {
 public:
  NopEventSource() : EventSource("nop") {}
};

VM::VM() {
#ifdef TOIT_POSIX
  ::signal(SIGPIPE, SIG_IGN);  // We check return values and don't want signals.
#endif

  ASSERT(_current == null);
  _current = this;

  OS::reset_monotonic_time();  // Reset "up time".
  Primitive::set_up();
  _heap_memory = _new HeapMemory();
  _program_heap_memory = _new ProgramHeapMemory();
  _scheduler = _new Scheduler();

  _event_manager = _new EventSourceManager();
  _nop_event_source = _new NopEventSource();
  _event_manager->add_event_source(_nop_event_source);
}

VM::~VM() {
  delete _event_manager;
  delete _scheduler;
  delete _heap_memory;
  delete _program_heap_memory;
  _current = null;
}

VM* VM::_current = null;

} // namespace toit

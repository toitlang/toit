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
#include "printing.h"
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

  ASSERT(current_ == null);
  current_ = this;

  OS::reset_monotonic_time();  // Reset "up time".
  Primitive::set_up();
  scheduler_ = _new Scheduler();

  event_manager_ = _new EventSourceManager();
  nop_event_source_ = _new NopEventSource();
  event_manager_->add_event_source(nop_event_source_);
}

VM::~VM() {
  delete event_manager_;
  delete scheduler_;
  current_ = null;
}

VM* VM::current_ = null;

#ifdef TOIT_DEBUG

void print_heap_console(ObjectHeap* heap, const char* title) {
  ConsolePrinter p(null);
  print_heap(&p, heap, title);
}

void print_heap(Printer* printer, ObjectHeap* heap, const char* title) {
  printer->printf("%s:\n", title);
  heap->do_objects([&] (HeapObject* object) -> void {
    print_object(printer, object);
  });
}

#endif

} // namespace toit

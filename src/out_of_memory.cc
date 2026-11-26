// Copyright (C) 2026 Toit contributors.
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

#include "out_of_memory.h"

#include <inttypes.h>
#include <stdio.h>

#include "os.h"
#include "process.h"
#include "process_group.h"
#include "scheduler.h"
#include "vm.h"

namespace toit {

void report_allocation_failure(Process* process, const char* reason, word parameter1, word parameter2) {
  Scheduler* scheduler = VM::current()->scheduler();
  bool is_system = scheduler->is_boot_process(process);
  word suppressed = 0;
  if (scheduler->should_report_allocation_failure(process, &suppressed)) {
    if (suppressed > 0) {
#ifdef TOIT_FREERTOS
      printf(
#else
      fprintf(stderr,
#endif
            "[out of memory: %" PRIdPTR " more failed allocations of process group %d since its last heap report]\n",
             suppressed, process->group()->id());
    }
    static const int BUFFER_SIZE = 50;
    char buffer[BUFFER_SIZE];
    snprintf(buffer, BUFFER_SIZE, "out of memory in %s %" PRIdPTR ":%" PRIdPTR,
             reason, parameter1, parameter2);
    buffer[BUFFER_SIZE - 1] = '\0';
    OS::heap_summary_report(0, buffer, process);
  }
  if (is_system) {
    OS::out_of_memory("Out of memory in system process");
  }
}

} // namespace toit

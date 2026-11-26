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
#include <stdlib.h>
#include <string.h>

#include "flags.h"
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
  if (!is_system) return;
  if (process->object_heap()->allocation_failure_recoverable()) {
    // A primitive the system process serves for another process (see
    // ObjectHeap::set_allocation_failure_recoverable): its last attempt
    // follows, and if that fails too, the operation fails with
    // OUT_OF_MEMORY for the system code that called it, which fails the
    // request.
#ifdef TOIT_FREERTOS
    printf(
#else
    fprintf(stderr,
#endif
           "[out of memory in system process: the operation fails, no restart]\n");
    return;
  }
  OS::out_of_memory("Out of memory in system process");
}

#ifdef TOIT_FREERTOS

bool inject_system_allocation_failure(Process* process, const char* site) {
  return false;
}

#else

bool inject_system_allocation_failure(Process* process, const char* site) {
  const char* spec = Flags::inject_system_oom;
  if (spec == null) return false;
  // Only the system process calls the primitives with injection sites, and
  // it runs on one thread at a time.
  static const int SITE_SIZE = 32;
  static char injected_site[SITE_SIZE];
  static int remaining = -1;
  if (remaining < 0) {
    const char* colon = strchr(spec, ':');
    if (colon == null || colon - spec >= SITE_SIZE) FATAL("-Xinject_system_oom: expected SITE:N, got '%s'", spec);
    memcpy(injected_site, spec, colon - spec);
    injected_site[colon - spec] = '\0';
    remaining = atoi(colon + 1);
    if (remaining < 0) FATAL("-Xinject_system_oom: negative count");
  }
  if (remaining == 0 || strcmp(site, injected_site) != 0) return false;
  if (!VM::current()->scheduler()->is_boot_process(process)) return false;
  remaining--;
  return true;
}

#endif

} // namespace toit

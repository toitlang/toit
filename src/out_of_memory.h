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

#pragma once

#include "top.h"

namespace toit {

class Process;

// The rate limit of the out-of-memory reports of one process group (a
// container). An allocation that still fails after the collections prints a
// heap report (OS::heap_summary_report: on a device a walk of the whole
// malloc heap and about 100 ms of UART output). A sandboxed container that
// keeps running into its quota or the sandbox heap floor would print one
// for every failure (397 in one device run, followed by a hang), so a
// group gets at most one full report per INTERVAL_US; the failures in
// between are only counted, and the count is printed with the next report.
// The first failure is always reported. Not thread-safe: the scheduler
// calls it with its lock held (Scheduler::should_report_allocation_failure).
class OutOfMemoryReportLimiter {
 public:
  static const int64 INTERVAL_US = 10LL * 1000 * 1000;

  // Whether the allocation failure at [now_us] (monotonic time) gets a full
  // report. If so, [suppressed] is set to the number of failures that were
  // not reported since the last full report; otherwise the failure is
  // counted.
  bool should_report(int64 now_us, word* suppressed) {
    if (has_reported_ && now_us - last_report_us_ < INTERVAL_US) {
      suppressed_++;
      return false;
    }
    *suppressed = suppressed_;
    suppressed_ = 0;
    last_report_us_ = now_us;
    has_reported_ = true;
    return true;
  }

  word suppressed() const { return suppressed_; }

 private:
  int64 last_report_us_ = 0;
  word suppressed_ = 0;
  bool has_reported_ = false;
};

// Reports an allocation of [process] that failed after the collections (the
// third failed attempt of the interpreters' retry loops, Interpreter::gc and
// v2_gc): a heap report (rate-limited for every process but the system
// process, see OutOfMemoryReportLimiter), and for the system process the
// restart of the device (OS::out_of_memory), unless the failing primitive
// declared its failure recoverable (ObjectHeap::set_allocation_failure_recoverable):
// then the primitive's last attempt follows and, if it fails too, the
// primitive throws OUT_OF_MEMORY in the system process. [reason],
// [parameter1] and [parameter2] name the failing operation in the report.
void report_allocation_failure(Process* process, const char* reason, word parameter1, word parameter2);

// Test hook, host only: whether the allocation at [site] fails in the system
// process. With -Xinject_system_oom=SITE:N the next N attempts at SITE fail
// (the sites: spawn, commit, header-page, reserve; one attempt sequence of
// a primitive is 4 calls). Always false on devices.
bool inject_system_allocation_failure(Process* process, const char* site);

} // namespace toit

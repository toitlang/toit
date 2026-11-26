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

#include <string.h>

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

  // Whether a failure of the group was reported (it had a failure).
  bool has_reported() const { return has_reported_; }

 private:
  int64 last_report_us_ = 0;
  word suppressed_ = 0;
  bool has_reported_ = false;
};

// Damps the restart loop of a sandboxed program that keeps dying of
// out-of-memory. A container that dies of it and is started again right
// away (by a trusted controller) takes its start-up memory each time and
// runs out again: on a device a worker was restarted 4 times in 5 seconds.
// The damper remembers, per program, how many sandboxed runs in a row died
// after running out of memory (they ended with a nonzero exit value after an
// allocation of their process group failed: a streak, reset when no such
// run ended for RESET_US) and when the last one ended; a sandboxed start of
// the program waits BASE_DELAY_US * 2^(streak - 1), at most MAX_DELAY_US,
// after that (Process::sandbox_start_allowed refuses it until then). A run
// that runs out of memory, handles it and ends normally doesn't count. It
// applies only with a sandbox heap floor. A fixed table of SLOTS programs,
// the least recent is replaced; a program is known by its id (its uuid: the
// host launches a new copy of a snapshot for every container). Not
// thread-safe: used under the process mutex (OS::process_mutex).
class SandboxRestartDamper {
 public:
  static const int SLOTS = 8;
  static const int MAX_STREAK = 16;
  static const int64 BASE_DELAY_US = 1000LL * 1000;
  static const int64 MAX_DELAY_US = 32LL * 1000 * 1000;
  static const int64 RESET_US = 60LL * 1000 * 1000;

  // Records that a sandboxed run of the program [program_id] died after
  // running out of memory, at [now_us].
  void note_failed_run(const uint8* program_id, int64 now_us) {
    Entry* entry = &entries_[0];
    for (int i = 0; i < SLOTS; i++) {
      if (entries_[i].is(program_id)) {
        entry = &entries_[i];
        break;
      }
      if (entries_[i].last_end_us < entry->last_end_us) entry = &entries_[i];
    }
    if (!entry->is(program_id)) {
      memcpy(entry->id, program_id, ID_SIZE);
      entry->used = true;
      entry->streak = 0;
    } else if (now_us - entry->last_end_us > RESET_US) {
      entry->streak = 0;
    }
    if (entry->streak < MAX_STREAK) entry->streak++;
    entry->last_end_us = now_us;
  }

  // How long a sandboxed start of the program [program_id] must still wait
  // at [now_us] (0: it may start).
  int64 delay_us(const uint8* program_id, int64 now_us) const {
    for (int i = 0; i < SLOTS; i++) {
      const Entry& entry = entries_[i];
      if (!entry.is(program_id) || entry.streak == 0) continue;
      int64 delay = BASE_DELAY_US << (entry.streak - 1);
      if (delay > MAX_DELAY_US) delay = MAX_DELAY_US;
      int64 until = entry.last_end_us + delay;
      return until > now_us ? until - now_us : 0;
    }
    return 0;
  }

 private:
  static const int ID_SIZE = 16;
  struct Entry {
    bool is(const uint8* program_id) const { return used && memcmp(id, program_id, ID_SIZE) == 0; }
    bool used = false;
    uint8 id[ID_SIZE] = {};
    int64 last_end_us = 0;
    int streak = 0;
  };
  Entry entries_[SLOTS];
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

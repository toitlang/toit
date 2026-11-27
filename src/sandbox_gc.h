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

// A copying collector for sandboxed (untrusted) processes: a prototype
// (gc/stage1, /home/flo/work/opentoit-sandbox-artifacts/gc-stage1/README.md).
//
// The heap of such a process is one space of pages (TOIT_PAGE_SIZE each;
// every object of a process heap is smaller than a page, larger data lives
// off-heap: ObjectHeap::max_allocation_size). Allocation bumps in the last
// page and takes a new page while the heap is below its limit. A
// collection is a Cheney copy of everything reachable from the roots into
// fresh pages taken one at a time; the old pages are freed afterwards.
// There is no old space, no promotion, no remembered set and no mark bits,
// so the core's write barrier has nothing to record for these processes.
//
// Opt-in, off by default: on hosts the environment variable
// TOIT_SANDBOX_GC=copying selects it for untrusted processes;
// TOIT_SANDBOX_GC=copying-all for every process (a test of the collector,
// not a configuration). Trusted processes keep the generational collector.
// TOIT_SANDBOX_GC=inplace (inplace-all) keeps this heap shape but collects
// without taking pages: mark, compute places, update, slide (a prototype
// for small devices, hosts only; src/sandbox_gc.cc).
//
// Statistics: TOIT_GC_STATS=1 prints one GCSTATS line per process heap when
// it is destroyed (both collectors).

#pragma once

#include "top.h"

namespace toit {

class Process;
class TwoSpaceHeap;

// Whether the heap of [process] (being constructed) uses the copying
// collector.
bool sandbox_copying_gc_wanted(Process* process);

// Per-heap collection statistics (only printed with TOIT_GC_STATS).
struct GcStats {
  static bool enabled();

  int pid = -1;
  bool untrusted = false;
  bool copying = false;
  uword collections = 0;     // Calls of TwoSpaceHeap::collect.
  uword scavenges = 0;
  uword full_gcs = 0;        // Mark-sweep or mark-compact of old space.
  uword compacting_gcs = 0;
  uword copying_gcs = 0;
  uint64 survivor_bytes = 0;      // Scavenges: bytes left in new space.
  uword max_survivor_bytes = 0;
  uint64 promoted_bytes = 0;      // Scavenges: bytes promoted to old space.
  uint64 copied_bytes = 0;        // Copying: bytes copied (all survivors).
  uword max_copied_bytes = 0;
  uint64 gc_instructions = 0;     // User-space instructions in collections.
  uint64 max_gc_instructions = 0;
  uint64 gc_us = 0;
  uint64 max_gc_us = 0;
  uword peak_pages = 0;           // Heap pages, including transient to-space.
  uword max_to_pages = 0;         // Copying: largest to-space (pages).
  uword max_from_pages = 0;       // Copying: largest from-space (pages).
  int max_to_over_from = 0;       // Copying: largest to/from page ratio (per mille).
  uint64 to_space_waste = 0;      // Copying: unused bytes at the end of to-space pages.
  // In-place collector (TOIT_SANDBOX_GC=inplace, hosts).
  bool inplace = false;
  uword inplace_gcs = 0;
  uint64 live_bytes = 0;          // In place: bytes marked.
  uword max_live_bytes = 0;
  uint64 moved_bytes = 0;         // In place: bytes slid.
  uword mark_rescans = 0;         // In place: heap rescans after a mark-stack overflow.
  uword max_mark_depth = 0;       // In place: deepest mark stack.
  uword max_kept_pages = 0;
  uint64 phase_instructions[4] = {0, 0, 0, 0};  // In place: mark, places, update, slide.

  void record_scavenge(uword survivors, uword promoted) {
    scavenges++;
    survivor_bytes += survivors;
    if (survivors > max_survivor_bytes) max_survivor_bytes = survivors;
    promoted_bytes += promoted;
  }
  // User-space instructions of the calling thread (0 when not available).
  static uint64 instructions();

  uint64 full_instructions = 0;   // Instructions of the old-space collections.
  uint64 full_live_bytes = 0;     // Sum of old-space used after them.
  uint64 full_space_bytes = 0;    // Sum of old-space size after them.

  void record_full(bool compacted, uint64 spent, uword live, uword space) {
    full_gcs++;
    if (compacted) compacting_gcs++;
    full_instructions += spent;
    full_live_bytes += live;
    full_space_bytes += space;
  }
  void record_copying(uword from_pages, uword to_pages, uword copied, uword waste);
  void record_inplace(uword pages_before, uword pages_after, uword live, uword moved, uword rescans, uword depth);
  void note_pages(uword pages) {
    if (pages > peak_pages) peak_pages = pages;
  }
  void print(TwoSpaceHeap* heap);
};

}  // namespace toit

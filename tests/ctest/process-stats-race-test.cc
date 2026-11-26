// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Reads the statistics of processes that collect garbage on other scheduler
// threads (Scheduler::process_stats, system.process-stats). The fixture
// spawns processes that allocate all the time and reads their statistics in
// a loop. process_stats holds only the scheduler lock, and the heap of a
// process changes without it (allocation and collections on the thread that
// runs the process): it used to read the heap of a process that was in the
// middle of a scavenge, whose new space had no chunk for a moment
// (TwoSpaceHeap::swap_semi_spaces), and crashed (LoadProhibited at address
// 0xc in SemiSpace::used on a device). Now another process's heap is read
// only while no thread runs or collects it; otherwise the numbers are those
// published when the process last stopped. Under ThreadSanitizer the old
// code reports data races here (and may crash without it).

#include "../../src/top.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/os.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"

int main(int argc, char** argv) {
  using namespace toit;
  if (argc != 2) FATAL("expected fixture source");
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  Flags::no_fork = true;
  auto bundle = SnapshotBundle::invalid();
  {
    compiler::Compiler compiler;
    bundle = compiler.compile(argv[1], null, null, {
      .dep_file = null,
      .dep_format = compiler::Compiler::DepFormat::none,
      .project_root = null,
      .force = false,
      .werror = true,
    });
  }
  if (!bundle.is_valid()) FATAL("fixture compilation failed");
  {
    VM vm;
    vm.load_platform_event_sources();
    auto image = bundle.snapshot().read_image(null);
    char* arguments[] = {null};
    auto exit = vm.scheduler()->run_boot_program(image.program(), arguments,
                                                 vm.scheduler()->next_group_id());
    image.release();
    if (exit.reason != Scheduler::EXIT_DONE) FATAL("fixture failed");
  }
  free(bundle.buffer());
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return 0;
}

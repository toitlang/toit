// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/os.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"
#include "../../src/third_party/dartino/gc_metadata.h"

#ifdef TOIT_POSIX
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

int main(int argc, char** argv) {
  using namespace toit;
  if (argc != 2) FATAL("expected fixture source");
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  // Exercise both the shared spare and the host's per-heap spare policy.
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
  uword baseline = ObjectMemory::allocated();
  for (int mode = 0; mode < 2; mode++) {
    GcMetadata::set_large_heap_heuristics(mode == 0 ? 0 : 100);
    for (int iteration = 0; iteration < 3; iteration++) {
      {
        VM vm;
        vm.load_platform_event_sources();
        auto image = bundle.snapshot().read_image(null);
        char argument[] = "unread startup argument";
        char* arguments[] = {argument, null};
        auto exit = vm.scheduler()->run_boot_program(image.program(), arguments,
                                                     vm.scheduler()->next_group_id());
        image.release();
        if (exit.reason != Scheduler::EXIT_DONE) FATAL("fixture failed");
      }
      if (ObjectMemory::allocated() != baseline) {
        FATAL("process retained GC chunks after termination");
      }
#ifdef TOIT_POSIX
      pid_t child = fork();
      if (child < 0) FATAL("fork failed");
      if (child == 0) _exit(23);
      int status;
      pid_t waited;
      do {
        waited = waitpid(child, &status, 0);
      } while (waited < 0 && errno == EINTR);
      if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 23) {
        FATAL("VM shutdown discarded a subsequent child exit status");
      }
#endif
    }
  }
  free(bundle.buffer());
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return 0;
}

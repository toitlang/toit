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

#include <errno.h>
#include <time.h>

#include "top.h"
#include "flags.h"
#include "flash_registry.h"
#include "main_utf_8_helper.h"
#include "messaging.h"
#include "native.h"
#include "objects_inline.h"
#include "os.h"
#include "process.h"
#include "scheduler.h"
#include "snapshot.h"
#include "snapshot_bundle.h"
#include "vm.h"
#include "third_party/dartino/gc_metadata.h"

namespace toit {

// The system process takes over the bundles, so it gets its own copies.
static SnapshotBundle copy_bundle(const NativeProgram* program) {
  uint8* copy = unvoid_cast<uint8*>(malloc(program->bundle_size));
  memcpy(copy, program->bundle, program->bundle_size);
  return SnapshotBundle(copy, program->bundle_size);
}

static int run_native_programs(char** argv) {
  const NativeProgram* system = NativeRuntime::registered_program(true);
  const NativeProgram* application = NativeRuntime::registered_program(false);
  if (system == null || application == null) FATAL("Missing native programs");
  ProgramImage system_image = NativeRuntime::load_image(system);
  while (true) {
    Scheduler::ExitState exit;
    { VM vm;
      vm.load_platform_event_sources();
      create_and_start_external_message_handlers(&vm);
      int group_id = vm.scheduler()->next_group_id();
      exit = vm.scheduler()->run_boot_program(
          system_image.program(), copy_bundle(system), copy_bundle(application), argv, group_id);
    }
    switch (exit.reason) {
      case Scheduler::EXIT_NONE:
        UNREACHABLE();

      case Scheduler::EXIT_DONE:
        return 0;

      case Scheduler::EXIT_ERROR:
        return exit.value;

      case Scheduler::EXIT_RESET:
        break;

      case Scheduler::EXIT_DEEP_SLEEP: {
        struct timespec sleep_time;
        sleep_time.tv_sec = exit.value / 1000;
        sleep_time.tv_nsec = (exit.value % 1000) * 1000000;
        while (nanosleep(&sleep_time, &sleep_time) != 0 && errno == EINTR) {}
        break;
      }
    }
  }
}

int main(int argc, char** argv) {
  Flags::program_name = argv[0];
  Flags::program_path = OS::get_executable_path();
  Flags::process_args(&argc, argv);

  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  // Drop the executable name.
  int exit_code = run_native_programs(argv + 1);

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_code;
}

}  // namespace toit

int main(int argc, char** argv) {
  return run_with_utf_8_args(toit::main, argc, argv);
}

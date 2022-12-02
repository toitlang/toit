// Copyright (C) 2022 Toitware ApS.
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
#include <libgen.h>

#include "top.h"
#include "run.h"
#include "interpreter.h"
#include "scheduler.h"
#include "vm.h"
#include "os.h"
#include "snapshot.h"
#include "snapshot_bundle.h"

#include "objects_inline.h"

extern "C" {
  extern unsigned char toit_run_snapshot[];
  extern unsigned int toit_run_snapshot_len;
};

namespace toit {

ProgramImage read_image_from_bundle(SnapshotBundle bundle) {
  if (!bundle.is_valid()) return ProgramImage::invalid();
  uint8 buffer[UUID_SIZE];
  uint8* id = bundle.uuid(buffer) ? buffer : null;
  return bundle.snapshot().read_image(id);
}

int run_program(const char* boot_bundle_path, SnapshotBundle application_bundle, char** argv) {
  if (boot_bundle_path != null) {
    auto boot_bundle = SnapshotBundle::read_from_file(boot_bundle_path, true);
    int result = run_program(boot_bundle, application_bundle, argv);
    // TODO(florian): we should free the boot_bundle buffer here, but that's already
    // done by the `run_program` as the buffer is sent in a message and then freed as an external byte array.
    return result;
  }
  // TODO(florian): we are currently doing a copy of the snapshot as the
  // snapshot is sent in a message, and then freed as part of the finalizer when
  // releasing external memory.
  auto copy = unvoid_cast<uint8*>(malloc(toit_run_snapshot_len));  // Never fails on host.
  memcpy(copy, toit_run_snapshot, toit_run_snapshot_len);
  SnapshotBundle boot_bundle(copy, toit_run_snapshot_len);
  return run_program(boot_bundle, application_bundle, argv);
}

int run_program(SnapshotBundle boot_bundle, SnapshotBundle application_bundle, char** argv) {
  while (true) {
    Scheduler::ExitState exit;
    { VM vm;
      vm.load_platform_event_sources();
      ProgramImage boot_image = read_image_from_bundle(boot_bundle);
      int group_id = vm.scheduler()->next_group_id();
      if (boot_image.is_valid()) {
        exit = vm.scheduler()->run_boot_program(
            boot_image.program(), boot_bundle, application_bundle, argv, group_id);
      } else {
        auto application_image = read_image_from_bundle(application_bundle);
        exit = vm.scheduler()->run_boot_program(application_image.program(), argv, group_id);
        application_image.release();
      }
      boot_image.release();
    }
    switch (exit.reason) {
      case Scheduler::EXIT_NONE:
        UNREACHABLE();

      case Scheduler::EXIT_DONE:
        return 0;

      case Scheduler::EXIT_ERROR:
        return exit.value;

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

} // namespace toit


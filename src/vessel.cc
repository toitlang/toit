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

#include "top.h"
#include "flags.h"
#include "run.h"
#include "flash_registry.h"
#include "os.h"
#include "third_party/dartino/gc_metadata.h"
#include "snapshot.h"
#include "snapshot_bundle.h"
#include "vessel/token.h"

#include "objects_inline.h"

// Each vessel has reserved data that is initialized with the vessel token.
// We replace this token with the data of the snapshot so we can execute it.
extern unsigned char vessel_snapshot_data[];

namespace toit {

// Prints the version and exits.
static void print_version() {
  printf("Toit version: %s\n", vm_git_version());
  exit(0);
}

static const uint8 kToken[] = VESSEL_TOKEN;

int main(int argc, char **argv) {
  Flags::process_args(&argc, argv);

  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  bool modified = false;
  for (int i = 0; i < sizeof(kToken); i++) {
    printf("checking %d\n", i);
    if (vessel_snapshot_data[i] != kToken[i]) {
      modified = true;
      break;
    }
  }
  if (!modified) {
    printf("Vessel has not been filled\n");
    return -1;
  }

  int snapshot_size = reinterpret_cast<uint32*>(vessel_snapshot_data)[0];
  uint8* snapshot = &vessel_snapshot_data[4];
  SnapshotBundle bundle(snapshot, snapshot_size);
  int exit_state = run_program(null, bundle, argv);

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_state;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}

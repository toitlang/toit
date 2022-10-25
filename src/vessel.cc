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

static const uint8 VESSEL_TOKEN[] = { VESSEL_TOKEN_VALUES };

int main(int argc, char **argv) {
  Flags::program_name = argv[0];
  Flags::process_args(&argc, argv);

  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  bool modified = false;
  for (size_t i = 0; i < sizeof(VESSEL_TOKEN); i++) {
    if (vessel_snapshot_data[i] != VESSEL_TOKEN[i]) {
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
  // TODO(florian): we currently create a copy, as the snapshot is freed at the end.
  // See run.cc.
  uint8* copy = unvoid_cast<uint8*>(malloc(snapshot_size));
  memcpy(copy, snapshot, snapshot_size);
  SnapshotBundle bundle(copy, snapshot_size);
  // Drop the executable name.
  argv++;
  int exit_code = run_program(null, bundle, argv);

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_code;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}

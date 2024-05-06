// Copyright (C) 2024 Toitware ApS.
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
#include "flash_registry.h"
#include "os.h"
#include "run.h"
#include "snapshot_bundle.h"

#include "objects_inline.h"

extern "C" {
  extern unsigned char toit_snapshot[];
  extern unsigned int toit_snapshot_len;
};

namespace toit {

int main(int argc, char **argv) {
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  int exit_state = 0;
  if (argc >= 2 && SnapshotBundle::is_bundle_file(argv[1])) {
    // Bundle reading.
    char* bundle_path = argv[1];
    Flags::program_name = bundle_path;
    Flags::program_path = OS::get_executable_path_from_arg(bundle_path);
    auto bundle = SnapshotBundle::read_from_file(bundle_path);
    exit_state = run_program(null, bundle, &argv[2]);
    // The bundle is put in an external ByteArray and automatically freed when
    // the heap is torn down.
    // TODO(florian): it looks like we don't free the bundle. There is a copy
    //   of the bundle in the byte-array (which is automatically freed), but the
    //   initial memory isn't released.
  } else {
    Flags::program_name = argv[0];
    Flags::program_path = OS::get_executable_path();
    // Launch the toit.toit program.
    // TODO(florian): we are currently doing a copy of the snapshot as the
    // snapshot is sent in a message, and then freed as part of the finalizer when
    // releasing external memory.
    auto copy = unvoid_cast<uint8*>(malloc(toit_snapshot_len));  // Never fails on host.
    memcpy(copy, toit_snapshot, toit_snapshot_len);
    SnapshotBundle toit_bundle(copy, toit_snapshot_len);
    exit_state = run_program(null, toit_bundle, &argv[1]);
  }

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_state;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}

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

// libFuzzer harness for the snapshot reader (src/snapshot.cc,
// Program::read, the read_content functions in src/objects.cc).
//
// The input is a raw program snapshot (the "snapshot" member of a snapshot
// bundle, as `snapshot.launch` receives it). If the input is a complete
// snapshot bundle (an ar archive), the bundle parser is exercised as well
// and its snapshot member is read.
//
// The reader must never crash or abort: malformed input yields an invalid
// ProgramImage.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../../src/top.h"
#include "../../src/flash_registry.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/program.h"
#include "../../src/snapshot.h"
#include "../../src/snapshot_bundle.h"

namespace toit {

static void touch_program(Program* program) {
  // Touch the tables the interpreter reads, so that the sanitizers catch
  // lists that point outside of the image.
  volatile uword sum = 0;
  for (int i = 0; i < program->bytecodes.length(); i++) sum += program->bytecodes[i];
  for (int i = 0; i < program->dispatch_table.length(); i++) sum += program->dispatch_table[i];
  for (int i = 0; i < program->class_bits.length(); i++) sum += program->class_bits[i];
  for (int i = 0; i < program->class_check_ids.length(); i++) sum += program->class_check_ids[i];
  for (int i = 0; i < program->interface_check_offsets.length(); i++) sum += program->interface_check_offsets[i];
  for (int i = 0; i < program->literals.length(); i++) sum += reinterpret_cast<uword>(program->literals.at(i)) & 1;
  for (int i = 0; i < program->global_variables.length(); i++) {
    sum += reinterpret_cast<uword>(program->global_variables.at(i)) & 1;
  }
}

static void read(const uint8* data, int size) {
  Snapshot snapshot(data, size);
  ProgramImage image = snapshot.read_image(null);
  if (!image.is_valid()) return;
  touch_program(image.program());
  image.release();
}

static void fuzz(const uint8* data, size_t size) {
  if (size > (1 << 24)) return;
  // The reader requires an aligned buffer, like the bundle reader provides.
  uint8* copy = unvoid_cast<uint8*>(malloc(size + 1));
  memcpy(copy, data, size);
  SnapshotBundle bundle(copy, static_cast<int>(size));
  if (size >= 8 && memcmp(copy, "!<arch>\n", 8) == 0 && bundle.is_valid()) {
    Snapshot snapshot = bundle.snapshot();
    if (snapshot.is_valid()) read(snapshot.buffer(), snapshot.size());
  } else {
    read(copy, static_cast<int>(size));
  }
  free(copy);
}

}  // namespace toit

extern "C" int LLVMFuzzerInitialize(int* argc, char*** argv) {
  using namespace toit;
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  toit::fuzz(data, size);
  return 0;
}

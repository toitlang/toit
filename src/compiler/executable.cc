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

#include "sources.h"

#include <stdio.h>

#include "../top.h"
#include "../snapshot_bundle.h"
#include "../vessel/token.h"
#include "executable.h"
#include "filesystem_local.h"
#include "util.h"

namespace toit {
namespace compiler {

static const uint8 kVesselToken[] = { VESSEL_TOKEN };
// We could generate this constant in the buildsystem, but that would make things
// just much more complicated for something that doesn't change that frequently.
static int kVesselSizes[] = { 150, 250, 500, 1000, 5000, };

int create_executable(const char* out_path, const SnapshotBundle& bundle) {
  FilesystemLocal fs;
  PathBuilder builder(&fs);
  builder.add(fs.vessel_root());
  bool found_vessel = false;
  for (int i = 0; sizeof(kVesselSizes); i++) {
    if (bundle.size() < kVesselSizes[i] * 1000) {
      builder.join(std::string("vessel") + std::to_string(kVesselSizes[i]));
      found_vessel = true;
      break;
    }
  }
  if (!found_vessel) {
    fprintf(stderr, "Snapshot too big: %d\n", bundle.size());
    return -1;
  }
  builder.canonicalize();
  const char* vessel_path = strdup(builder.c_str());
  FILE* file = fopen(vessel_path, "rb");
  if (!file) {
    fprintf(stderr, "Unable to open vessel file %s\n", vessel_path);
    return -1;
  }
  // Find content size of file.
  fseek(file, 0, SEEK_END);
  long fsize = ftell(file);
  int size = fsize;
  // Read entire content.
  uint8* vessel_content = unvoid_cast<uint8*>(malloc(size));
  if (vessel_content == null) {
    fprintf(stderr, "Unable to allocate buffer for vessel %s\n", vessel_path);
    return -1;
  }
  fseek(file, 0, SEEK_SET);
  int read_count = fread(vessel_content, fsize, 1, file);
  fclose(file);
  if (read_count != 1) {
    free(vessel_content);
    fprintf(stderr, "Unable to read vessel '%s'\n", vessel_path);
    return -1;
  }
  for (size_t i = 0; i < size - sizeof(kVesselToken); i++) {
    bool found_token = true;
    // We must find two copies of the token next to each other.
    for (size_t j = 0; j < sizeof(kVesselToken) * 2; j++) {
      if (vessel_content[i + j] != kVesselToken[j % sizeof(kVesselToken)]) {
        found_token = false;
        break;
      }
    }
    if (found_token) {
      *reinterpret_cast<uint32*>(&vessel_content[i]) = bundle.size();
      memcpy(&vessel_content[i + 4], bundle.buffer(), bundle.size());
      FILE* file_out = fopen(out_path, "wb");
      fwrite(vessel_content, size, 1, file_out);
      fclose(file_out);
      return 0;
    }
  }
  fprintf(stderr, "Invalid vessel file. Token not found\n");
  return -1;
}


} // namespace toit::compiler
} // namespace toit

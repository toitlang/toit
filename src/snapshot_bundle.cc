// Copyright (C) 2020 Toitware ApS.
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

#include "snapshot_bundle.h"
#include "compiler/ar.h"

namespace toit {

static const char* const MAGIC_NAME = "toit";
static const char* const MAGIC_CONTENT = "like a tiger";
static const char* const SNAPSHOT_NAME = "snapshot";
static const char* const SOURCE_MAP_NAME = "source-map";
static const char* const DEBUG_SNAPSHOT_NAME = "D-snapshot";
static const char* const DEBUG_SOURCE_MAP_NAME = "D-source-map";

SnapshotBundle::SnapshotBundle(List<uint8> snapshot,
                               List<uint8> source_map_data,
                               List<uint8> debug_snapshot,
                               List<uint8> debug_source_map_data) {
  ar::MemoryBuilder builder;
  int status = builder.open();
  if (status != 0) FATAL("Couldn't create snapshot");
  ar::File magic_file(
    MAGIC_NAME, ar::AR_DONT_FREE,
    reinterpret_cast<const uint8*>(MAGIC_CONTENT), ar::AR_DONT_FREE,
    static_cast<int>(strlen(MAGIC_CONTENT)));
  status = builder.add(magic_file);
  if (status != 0) FATAL("Couldn't create snapshot");

  // Nested function to add the lists as files to the snapshot.
  auto add = [&](const char* name, List<uint8> bytes) {
    ar::File file(
      name, ar::AR_DONT_FREE,
      bytes.data(), ar::AR_DONT_FREE,
      bytes.length());
    int status = builder.add(file);
    if (status != 0) FATAL("Couldn't create snapshot");
  };

  add(SNAPSHOT_NAME, snapshot);
  add(SOURCE_MAP_NAME, source_map_data);
  add(DEBUG_SNAPSHOT_NAME, debug_snapshot);
  add(DEBUG_SOURCE_MAP_NAME, debug_source_map_data);

  builder.close(&_buffer, &_size);
}

bool SnapshotBundle::is_bundle_file(FILE* file) {
  ar::FileReader ar_reader(file);
  ar::File first_ar_file;
  int status = ar_reader.next(&first_ar_file);
  bool result = status == 0 &&
      strcmp(MAGIC_NAME, first_ar_file.name()) == 0 &&
      strncmp(MAGIC_CONTENT,
              reinterpret_cast<const char*>(first_ar_file.content()),
              strlen(MAGIC_CONTENT)) == 0;
  first_ar_file.free_name();
  first_ar_file.free_content();
  return result;
}

bool SnapshotBundle::is_bundle_file(const char* path) {
  FILE* file = fopen(path, "rb");
  if (file == null) return false;
  bool result = is_bundle_file(file);
  fclose(file);
  return result;
}

Snapshot SnapshotBundle::snapshot() {
  ar::MemoryReader reader(_buffer, _size);
  ar::File file;
  int status = reader.find("snapshot", &file);
  if (status != 0) FATAL("Invalid SnapshotBundle");
  return Snapshot(file.content(), file.byte_size);
}

SnapshotBundle SnapshotBundle::read_from_file(const char* bundle_filename, bool silent) {
  FILE *file;
  file = fopen(bundle_filename, "rb");
  if (!file) {
    if (silent) return SnapshotBundle::invalid();
    fprintf(stderr, "Unable to open snapshot file %s\n", bundle_filename);
    return invalid();
  }
  if (!is_bundle_file(file)) {
    if (silent) return SnapshotBundle::invalid();
    fprintf(stderr, "Not a valid snapshot file %s\n", bundle_filename);
    return invalid();
  }
  // Find content size of file.
  fseek(file, 0, SEEK_END);
  long fsize = ftell(file);
  int size = fsize;
  // Read entire content.
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  if (buffer == null) {
    if (silent) return SnapshotBundle::invalid();
    fprintf(stderr, "Unable to allocate buffer for snapshot %s\n", bundle_filename);
    return invalid();
  }
  fseek(file, 0, SEEK_SET);
  int read_count = fread(buffer, fsize, 1, file);
  fclose(file);
  if (read_count != 1) {
    free(buffer);
    if (silent) return SnapshotBundle::invalid();
    fprintf(stderr, "Unable to read snapshot buffer for %s\n", bundle_filename);
    return invalid();
  }
  return SnapshotBundle(buffer, size);
}

bool SnapshotBundle::write_to_file(const char* bundle_filename, bool silent) {
  FILE* file = fopen(bundle_filename, "wb");
  if (!file) {
    if (!silent) {
      fprintf(stderr, "Unable to open snapshot file %s\n", bundle_filename);
    }
    return false;
  }
  fwrite(buffer(), size(), 1, file);
  fclose(file);
  return true;
}

} // namespace toit

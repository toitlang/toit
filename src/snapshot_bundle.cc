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

#include "top.h"
#include "uuid.h"
#include <mbedtls/sha256.h>
#if MBEDTLS_VERSION_MAJOR >= 3
// Bring back the _ret names for sha functions.
#include <mbedtls/compat-2.x.h>
#endif

#ifndef TOIT_FREERTOS

#include "snapshot_bundle.h"
#include "ar.h"

namespace toit {

static const char* const MAGIC_NAME = "toit";
static const char* const MAGIC_CONTENT = "like a tiger";
static const char* const UUID_NAME = "uuid";
static const char* const SDK_VERSION_NAME = "sdk-version";
static const char* const SNAPSHOT_NAME = "snapshot";
static const char* const SOURCE_MAP_NAME = "source-map";
static const char* const DEBUG_SNAPSHOT_NAME = "D-snapshot";
static const char* const DEBUG_SOURCE_MAP_NAME = "D-source-map";

static void update_sha256(mbedtls_sha256_context* context, const uint8* bytes, size_t length) {
  uint8 length_bytes[sizeof(uint32)];
  Utils::write_unaligned_uint32_le(length_bytes, length);
  mbedtls_sha256_update_ret(context, length_bytes, sizeof(length_bytes));
  mbedtls_sha256_update_ret(context, bytes, length);
}

SnapshotBundle::SnapshotBundle(List<uint8> snapshot,
                               List<uint8> source_map_data,
                               List<uint8> debug_snapshot,
                               List<uint8> debug_source_map_data)
    : SnapshotBundle(snapshot, &source_map_data, &debug_snapshot, &debug_source_map_data, vm_git_version()) {}

SnapshotBundle::SnapshotBundle(List<uint8> snapshot,
                               List<uint8>* source_map_data,
                               List<uint8>* debug_snapshot,
                               List<uint8>* debug_source_map_data,
                               const char* sdk_version) {
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

  size_t sdk_version_length = strlen(sdk_version);
  ar::File version_file(
    SDK_VERSION_NAME, ar::AR_DONT_FREE,
    reinterpret_cast<const uint8*>(sdk_version), ar::AR_DONT_FREE,
    static_cast<int>(sdk_version_length));
  status = builder.add(version_file);
  if (status != 0) FATAL("Couldn't create snapshot");

  // Generate UUID using sha256 checksum of:
  //   version
  //   snapshot
  mbedtls_sha256_context sha_context;
  mbedtls_sha256_init(&sha_context);
  static const int SHA256 = 0;
  static const int SHA256_HASH_LENGTH = 32;
  mbedtls_sha256_starts_ret(&sha_context, SHA256);

  // Add hashed components.
  const uint8* version_uint8 = reinterpret_cast<const uint8*>(sdk_version);
  update_sha256(&sha_context, version_uint8, sdk_version_length);
  update_sha256(&sha_context, snapshot.data(), snapshot.length());

  uint8 sum[SHA256_HASH_LENGTH];
  mbedtls_sha256_finish_ret(&sha_context, sum);
  mbedtls_sha256_free(&sha_context);

  // Fix checksum bytes to make a UUID5-like ID.
  sum[6] = (sum[6] & 0xf) | 0x50;
  sum[8] = (sum[8] & 0x3f) | 0x80;

  // The order of the following AR-files is important.
  // When reading the snapshot, an iterator is used to find the individual
  // files, and changing the order would make the iterator miss the files.
  add(SNAPSHOT_NAME, snapshot);
  add(UUID_NAME, List<uint8>(sum, UUID_SIZE));
  if (source_map_data != null) add(SOURCE_MAP_NAME, *source_map_data);
  if (debug_snapshot != null) add(DEBUG_SNAPSHOT_NAME, *debug_snapshot);
  if (debug_source_map_data != null) add(DEBUG_SOURCE_MAP_NAME, *debug_source_map_data);

  builder.close(&buffer_, &size_);
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
  ar::MemoryReader reader(buffer_, size_);
  ar::File file;
  int status = reader.find("snapshot", &file);
  if (status != 0) FATAL("Invalid SnapshotBundle");
  return Snapshot(file.content(), file.byte_size);
}

bool SnapshotBundle::uuid(uint8* buffer_16) const {
  ar::MemoryReader reader(buffer_, size_);
  ar::File file;
  int status = reader.find("uuid", &file);
  if (status != 0 || file.byte_size < UUID_SIZE) return false;
  memcpy(buffer_16, file.content(), UUID_SIZE);
  return true;
}

SnapshotBundle SnapshotBundle::stripped() const {
  List<uint8> snapshot_bytes;
  const char* sdk_version = null;
  ar::MemoryReader reader(buffer_, size_);
  ar::File file;
  while (reader.next(&file) == 0) {
    if (strcmp(file.name(), SNAPSHOT_NAME) == 0) {
      // We are just passing the list along.
      // The const cast should be safe.
      snapshot_bytes = List<uint8>(const_cast<uint8*>(file.content()), file.byte_size);
    } else if (strcmp(file.name(), SDK_VERSION_NAME) == 0) {
      // Copy the sdk-version so it's null terminated.
      int sdk_len = file.byte_size;
      char* buffer = unvoid_cast<char*>(malloc(sdk_len + 1));
      memcpy(buffer, file.content(), sdk_len);
      buffer[sdk_len] = '\0';
      sdk_version = buffer;
    }
  }
  return SnapshotBundle(snapshot_bytes, null, null, null, sdk_version);
}

SnapshotBundle SnapshotBundle::read_from_file(const char* bundle_filename, bool silent) {
  FILE* file = fopen(bundle_filename, "rb");
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

#endif  // TOIT_FREERTOS

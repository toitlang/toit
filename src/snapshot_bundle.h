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

#pragma once

#ifndef TOIT_FREERTOS

#include <stdio.h>

#include "top.h"
#include "snapshot.h"
#include "utils.h"

namespace toit {

class SnapshotBundle {
 public:
  SnapshotBundle(uint8* buffer, int size)
      : buffer_(buffer), size_(size) {}

  /// Returns a new SnapshotBundle, where the buffer is allocated with 'malloc'.
  /// The given data is not reused and can be freed.
  SnapshotBundle(List<uint8> main_snapshot,
                 List<uint8> main_source_map_data,
                 List<uint8> debug_snapshot,
                 List<uint8> debug_source_map_data);

  static SnapshotBundle invalid() { return SnapshotBundle(null, 0); }

  /// Reads a snapshot bundle from the given [path].
  /// If successful, allocates the buffer using `malloc` and returns
  ///   a valid bundle.
  /// Otherwise returns an invalid bundle. If [silent] is false,
  /// also writes an error message on stderr.
  static SnapshotBundle read_from_file(const char* path, bool silent = false);

  /// Writes this bundle to the given [path].
  /// If successful, returns true.
  /// Otherwise returns false. If [silent] is false,
  /// also writes an error message on stderr.
  bool write_to_file(const char* path, bool silent = false);

  bool is_valid() const { return buffer_ != null; }

  Snapshot snapshot();

  uint8* buffer() { return buffer_; }
  const uint8* buffer() const { return buffer_; }
  int size() const { return size_; }

  // Read the UUID from the file into a 16 byte buffer.  Returns false if the
  // UUID was not in the snapshot file.
  bool uuid(uint8* buffer_16) const;

  // Builds a snapshot bundle without debugging information.
  // The old and new bundle don't share any code, and this instance's
  // buffer can be safely freed.
  SnapshotBundle stripped() const;

  /// Whether the given [file] is likely a bundle file.
  /// This function is applying a heuristic to determine whether
  /// the content looks like a bundle file.
  static bool is_bundle_file(FILE* file);
  static bool is_bundle_file(const char* path);

 private:
  uint8* buffer_;
  int size_;

  /// Returns a new SnapshotBundle, where the buffer is allocated with 'malloc'.
  /// The given data is not reused and can be freed.
  /// The source-maps are optional in this constructor.
  SnapshotBundle(List<uint8> main_snapshot,
                 List<uint8>* main_source_map_data,
                 List<uint8>* debug_snapshot,
                 List<uint8>* debug_source_map_data,
                 const char* sdk_version);


};

} // namespace toit

#endif  // TOIT_FREERTOS

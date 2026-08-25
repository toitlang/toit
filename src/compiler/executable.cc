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

#include "sources.h"

#include <stdio.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

#ifdef TOIT_WINDOWS
#include <io.h>
#else
#include <unistd.h>
#endif

#ifdef TOIT_DARWIN
// For spawning codesign.
#include <spawn.h>
#include <sys/wait.h>
extern "C" char** environ;
#endif

#include "../top.h"
#include "../snapshot_bundle.h"
#include "../vessel/token.h"
#include "executable.h"
#include "filesystem_local.h"
#include "util.h"

namespace toit {
namespace compiler {

static const char* EXECUTABLE_SUFFIXES[] = { "", ".exe" };

#ifndef O_BINARY
// On Windows `O_BINARY` is necessary to avoid newline conversions.
#define O_BINARY 0
#endif

static const uint8 VESSEL_TOKEN[] = { VESSEL_TOKEN_VALUES };
// We could generate this constant in the build system, but that would make things
// just much more complicated for something that doesn't change that frequently.
static int VESSEL_SIZES[] = { 128, 256, 512, 1024, 8192, };

static int sign_if_necessary(const char* out_path, const char* os) {
#ifndef TOIT_DARWIN
  // TODO(florian): sign if os equals "macos".
  return 0;
#else
  if (os != null) {
    return 0;
  }
  char codesign[] = { "codesign" };
  char minus_fs[] = { "-fs" };
  char dash[] = { "-" };
  char* out_path_mutable = strdup(out_path);
  // The spawn functions want mutable argv arguments. They are unlikely to modify it, but that's what it wants.
  char* argv[] = { codesign, minus_fs, dash, out_path_mutable, null };
  int status = 0;
  pid_t child_pid;
  if (posix_spawnp(&child_pid, "codesign", null, null, argv, environ) != 0) goto fail;
  do {
    if (waitpid(child_pid, &status, 0) == -1) goto fail;
  } while (WIFEXITED(status) == 0 && WIFSIGNALED(status) == 0);

  free(out_path_mutable);
  if (WIFEXITED(status) != 0) return WEXITSTATUS(status);
  if (WIFSIGNALED(status) != 0) return -1;

   fail:
    perror("sign_if_necessary");
    free(out_path_mutable);
    return -1;
#endif
}

int create_executable(const char* out_path,
                      const SnapshotBundle& bundle,
                      const char* vessel_root,
                      const char* os,
                      const char* arch) {
  FilesystemLocal fs;
  PathBuilder builder(&fs);
  if (vessel_root != null) {
    builder.add(vessel_root);
  } else {
    vessel_root = fs.vessel_root();
    builder.add(vessel_root);
  }
  if (os != null) {
    builder.join(os);
    if (strcmp(os, "darwin") == 0 && strcmp(arch, "amd64") == 0) {
      // We now have fat binaries that combine arm64 and x64.
      arch = "aarch64";
    }
  }
  if (arch != null) {
    // If we have an arch, we should always have an os, but we
    // don't check for it here.
    builder.join(arch);
  }
  bool found_vessel = false;
  for (unsigned int i = 0; i < ARRAY_SIZE(VESSEL_SIZES); i++) {
    if (bundle.size() < VESSEL_SIZES[i] * 1024) {
      builder.join(std::string("vessel") + std::to_string(VESSEL_SIZES[i]));
      found_vessel = true;
      break;
    }
  }
  if (!found_vessel) {
    fprintf(stderr, "Snapshot too big: %d\n", bundle.size());
    return -1;
  }
  builder.canonicalize();
  int length_without_extension = builder.length();
  FILE* file = null;
  std::string vessel_path;
  for (unsigned int i = 0; i < ARRAY_SIZE(EXECUTABLE_SUFFIXES); i++) {
    builder.reset_to(length_without_extension);
    builder.add(EXECUTABLE_SUFFIXES[i]);
    vessel_path = builder.c_str();
    struct stat buffer;
    if (stat(vessel_path.c_str(), &buffer) != 0) {
      continue;
    }
    file = fopen(vessel_path.c_str(), "rb");
    if (file == null) {
      fprintf(stderr, "Unable to open vessel file %s\n", vessel_path.c_str());
      return -1;
    }
    break;
  }
  if (file == null) {
    if (os != null || arch != null) {
      fprintf(stderr, "Unable to find cross-compilation vessel file for %s-%s in %s\n", os, arch, vessel_root);
    } else {
      fprintf(stderr, "Unable to find vessel file in %s\n", vessel_root);
    }
    return -1;
  }
  Defer close_file { [&] { if (file != null) fclose(file); } };
  // Find content size of file.
  int status = fseek(file, 0, SEEK_END);
  if (status != 0) {
    perror("create_executable");
    return -1;
  }
  long fsize = ftell(file);
  if (fsize < 0 || fsize > INT_MAX) {
    fprintf(stderr, "Invalid vessel size for '%s'\n", vessel_path.c_str());
    return -1;
  }
  int size = fsize;
  // Read entire content.
  uint8* vessel_content = unvoid_cast<uint8*>(malloc(size));
  if (vessel_content == null) {
    fprintf(stderr, "Unable to allocate buffer for vessel %s\n", vessel_path.c_str());
    return -1;
  }
  Defer free_vessel_content { [&] { free(vessel_content); } };
  status = fseek(file, 0, SEEK_SET);
  if (status != 0) {
    perror("create_executable");
    return -1;
  }
  int read_count = fread(vessel_content, fsize, 1, file);
  fclose(file);
  file = null;
  if (read_count != 1) {
    fprintf(stderr, "Unable to read vessel '%s'\n", vessel_path.c_str());
    return -1;
  }
  bool replaced_vessel_content = false;
  size_t vessel_size = static_cast<size_t>(size);
  for (size_t i = 0; i + 2 * sizeof(VESSEL_TOKEN) <= vessel_size; i++) {
    bool found_token = true;
    // We must find two copies of the token next to each other.
    for (size_t j = 0; j < sizeof(VESSEL_TOKEN) * 2; j++) {
      if (vessel_content[i + j] != VESSEL_TOKEN[j % sizeof(VESSEL_TOKEN)]) {
        found_token = false;
        break;
      }
    }
    if (found_token) {
      size_t bundle_size = static_cast<size_t>(bundle.size());
      if (i + sizeof(uint32) + bundle_size > vessel_size) continue;
      uint32 encoded_size = bundle.size();
      memcpy(&vessel_content[i], &encoded_size, sizeof(encoded_size));
      memcpy(&vessel_content[i + sizeof(encoded_size)], bundle.buffer(), bundle_size);
      replaced_vessel_content = true;
      // Some architectures (macos fat binaries) have multiple executables
      // in the same file, so we need to replace all occurrences of the token.
      i += bundle_size;
    }
  }

  if (!replaced_vessel_content) {
    fprintf(stderr, "Invalid vessel file. Token not found\n");
    return -1;
  }

  // Use 'open', so we can give executable permissions.
  int fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY, 0777);
  if (fd < 0) {
    perror("create_executable");
    return -1;
  }
  FILE* file_out = fdopen(fd, "wb");
  if (file_out == NULL) {
#ifdef TOIT_WINDOWS
    _close(fd);
#else
    close(fd);
#endif
    perror("create_executable");
    return -1;
  }
  Defer close_output { [&] { if (file_out != null) fclose(file_out); } };
  int written = fwrite(vessel_content, 1, size, file_out);
  if (written != size) {
    perror("create_executable");
    return -1;
  }
  if (fclose(file_out) != 0) {
    file_out = null;
    perror("create_executable");
    return -1;
  }
  file_out = null;
  if (sign_if_necessary(out_path, os) != 0) {
    fprintf(stderr, "Error while signing the generated executable '%s'. The program might still work.\n", out_path);
  }
  return 0;
}


} // namespace toit::compiler
} // namespace toit

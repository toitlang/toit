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

#ifdef TOIT_WINDOWS
static const char* EXECUTABLE_SUFFIX = ".exe";
#else
static const char* EXECUTABLE_SUFFIX = "";
#endif

#ifndef O_BINARY
// On Windows `O_BINARY` is necessary to avoid newline conversions.
#define O_BINARY 0
#endif

static const uint8 VESSEL_TOKEN[] = { VESSEL_TOKEN_VALUES };
// We could generate this constant in the build system, but that would make things
// just much more complicated for something that doesn't change that frequently.
static int VESSEL_SIZES[] = { 128, 256, 512, 1024, 8192, };

static int sign_if_necessary(const char* out_path) {
#ifndef TOIT_DARWIN
  return 0;
#else
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

int create_executable(const char* out_path, const SnapshotBundle& bundle) {
  FilesystemLocal fs;
  PathBuilder builder(&fs);
  builder.add(fs.vessel_root());
  bool found_vessel = false;
  for (int i = 0; ARRAY_SIZE(VESSEL_SIZES); i++) {
    if (bundle.size() < VESSEL_SIZES[i] * 1024) {
      builder.join(std::string("vessel") + std::to_string(VESSEL_SIZES[i]) + std::string(EXECUTABLE_SUFFIX));
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
  int status = fseek(file, 0, SEEK_END);
  if (status != 0) {
    perror("create_executable");
    return -1;
  }
  long fsize = ftell(file);
  int size = fsize;
  // Read entire content.
  uint8* vessel_content = unvoid_cast<uint8*>(malloc(size));
  if (vessel_content == null) {
    fprintf(stderr, "Unable to allocate buffer for vessel %s\n", vessel_path);
    return -1;
  }
  status = fseek(file, 0, SEEK_SET);
  if (status != 0) {
    perror("create_executable");
    return -1;
  }
  int read_count = fread(vessel_content, fsize, 1, file);
  fclose(file);
  if (read_count != 1) {
    free(vessel_content);
    fprintf(stderr, "Unable to read vessel '%s'\n", vessel_path);
    return -1;
  }
  for (size_t i = 0; i < size - sizeof(VESSEL_TOKEN); i++) {
    bool found_token = true;
    // We must find two copies of the token next to each other.
    for (size_t j = 0; j < sizeof(VESSEL_TOKEN) * 2; j++) {
      if (vessel_content[i + j] != VESSEL_TOKEN[j % sizeof(VESSEL_TOKEN)]) {
        found_token = false;
        break;
      }
    }
    if (found_token) {
      *reinterpret_cast<uint32*>(&vessel_content[i]) = bundle.size();
      memcpy(&vessel_content[i + 4], bundle.buffer(), bundle.size());
      // Use 'open', so we can give executable permissions.
      int fd = open(out_path, O_WRONLY | O_CREAT | O_BINARY, 0777);
      FILE* file_out = fdopen(fd, "wb");
      if (file_out == NULL) {
        perror("create_executable");
        return -1;
      }
      int written = fwrite(vessel_content, 1, size, file_out);
      if (written != size) {
        perror("create_executable");
        return -1;
      }
      fclose(file_out);
      if (sign_if_necessary(out_path) != 0) {
        fprintf(stderr, "Error while signing the generated executable '%s'. The program might still work.\n", out_path);
      }
      return 0;
    }
  }
  fprintf(stderr, "Invalid vessel file. Token not found\n");
  return -1;
}


} // namespace toit::compiler
} // namespace toit

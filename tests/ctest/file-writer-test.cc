// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include <string>

#ifdef TOIT_WINDOWS
#include <io.h>
#else
#include <unistd.h>
#endif

#include "../../src/file_writer.h"
#include "../../src/top.h"

namespace toit {

static std::string read_file(const std::string& path) {
  FILE* file = fopen(path.c_str(), "rb");
  ASSERT(file != null);
  ASSERT(fseek(file, 0, SEEK_END) == 0);
  long size = ftell(file);
  ASSERT(size >= 0);
  ASSERT(fseek(file, 0, SEEK_SET) == 0);
  std::string result(size, '\0');
  ASSERT(size == 0 || fread(&result[0], 1, size, file) == size);
  ASSERT(fclose(file) == 0);
  return result;
}

static void remove_file(const std::string& path) {
#ifdef TOIT_WINDOWS
  _unlink(path.c_str());
#else
  unlink(path.c_str());
#endif
}

static void set_mode(const std::string& path, int mode) {
#ifdef TOIT_WINDOWS
  ASSERT(_chmod(path.c_str(), mode) == 0);
#else
  ASSERT(chmod(path.c_str(), mode) == 0);
#endif
}

static void test_atomic_file_writer(const char* executable_path) {
  std::string path = std::string(executable_path) + ".atomic-output";
  remove_file(path);

  const char* first = "first contents\n";
  ASSERT(write_file_atomically(
      path.c_str(), reinterpret_cast<const uint8*>(first), strlen(first), 0600));
  ASSERT(read_file(path) == first);

  set_mode(path, 0640);
  const char* second = "replacement contents\n";
  ASSERT(write_file_atomically(
      path.c_str(), reinterpret_cast<const uint8*>(second), strlen(second)));
  ASSERT(read_file(path) == second);

#ifndef TOIT_WINDOWS
  struct stat status;
  ASSERT(stat(path.c_str(), &status) == 0);
  ASSERT((status.st_mode & 0777) == 0640);
#endif

  set_mode(path, 0440);
  ASSERT(!write_file_atomically(
      path.c_str(), reinterpret_cast<const uint8*>(first), strlen(first)));
  ASSERT(read_file(path) == second);

  set_mode(path, 0600);
  remove_file(path);
}

} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);
  toit::test_atomic_file_writer(argv[0]);
  return 0;
}

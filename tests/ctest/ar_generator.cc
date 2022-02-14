// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <limits.h>

#include "../../src/compiler/ar.h"
#include "../../src/compiler/list.h"
#include "../../src/compiler/tar.h"
#include "../../src/utils.h"

namespace toit {

using namespace compiler;

void write_to_memory(List<ar::File> files, uint8** buffer, int* size) {
  ar::MemoryBuilder memory_builder;
  int status = memory_builder.open();
  for (auto file : files) {
    status = memory_builder.add(file);
    if (status != 0) FATAL("Couldn't allocate memory");
  }
  memory_builder.close(buffer, size);
}

void write_to_file(List<ar::File> files, const char* path) {
  ar::FileBuilder file_builder;
  int status = file_builder.open(path);
  if (status != 0) FATAL("Couldn't open file");
  for (auto file : files) {
    status = file_builder.add(file);
    if (status != 0) FATAL("Couldn't write to file");
  }
  status = file_builder.close();
  if (status != 0) FATAL("Couldn't close file");
}

int main(int argc, char** argv) {
  throwing_new_allowed = true;
  bool in_memory = false;
  if (argc == 3) {
    if (strcmp(argv[2], "--memory") != 0) FATAL("Unexpected args");
    in_memory = true;
  }
  if (argc != 2 and argc != 3) {
    FATAL("Unexpected args");
  }
  const char* path = argv[1];
  ListBuilder<ar::File> ar_files;

  untar(stdin, [&](const char* name, char* content, int size) {
    ar::File file(
        name, ar::AR_DONT_FREE,
        unsigned_cast(content), ar::AR_DONT_FREE,
        size);
    ar_files.add(file);
  });

  if (in_memory) {
    uint8* buffer;
    int size;
    write_to_memory(ar_files.build(), &buffer, &size);
    FILE* f = fopen(path, "wb");
    if (f == null) FATAL("Couldn't open file");
    int written = fwrite(buffer, 1, size, f);
    if (written != size) FATAL("Error while writing to file");
    int status = fclose(f);
    if (status != 0) FATAL("Error while closing file");
    free(buffer);
  } else {
    write_to_file(ar_files.build(), path);
  }

  return 0;
}

}

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}

// Copyright (C) 2020 Toitware ApS. All rights reserved.

#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <unistd.h>
#include <string>
#include <vector>
#include <unordered_set>

#include "../../src/top.h"
#include "../../src/compiler/ar.h"
#include "../../src/compiler/list.h"
#include "../../src/utils.h"

#ifdef WIN32
static char* mkdtemp(char* tmpl) {
  UNIMPLEMENTED();
}
#endif

namespace toit {

using namespace compiler;

// Required for linking.
unsigned int checksum[4] = { 0, 0, 0, 0};

template <typename T>
void do_test(List<ar::File> test, T& reader) {
  std::unordered_set<std::string> seen;
  ar::File file;
  while (true) {
    int status = reader.next(&file);
    if (status == ar::AR_END_OF_ARCHIVE) break;
    if (status == ar::AR_ERRNO_ERROR) FATAL("Error while reading");
    if (status == ar::AR_OUT_OF_MEMORY) FATAL("Error out of memory");
    if (status == ar::AR_FORMAT_ERROR) FATAL("Bad format");
    if (status != 0) FATAL("Unexpected code");
    seen.insert(std::string(file.name()));
    bool found = false;
    for (auto expected : test) {
      if (strcmp(expected.name(), file.name()) != 0) continue;
      found = true;
      if (expected.byte_size != file.byte_size) FATAL("Not same size");
      if (memcmp(expected.content(), file.content(), expected.byte_size) != 0) {
        FATAL("Not same content");
      }
      break;
    }
    file.free_name();
    if (!found) FATAL("Unexpected file in archive");
  }
  if (test.length() != static_cast<int>(seen.size())) FATAL("Missing files");

  // Test 'find' method.
  ar::File ar_file;
  int status = reader.find("not there", &ar_file);
  if (status != ar::AR_NOT_FOUND) FATAL("Non-existing file found");
  for (auto test_file : test) {
    status = reader.find(test_file.name(), &ar_file);
    if (status != 0) FATAL("Ar File not found");
    if (strcmp(ar_file.name(), test_file.name()) != 0) FATAL("Not using given name");
  }
  for (int i = test.length() - 1; i >= 0; i--) {
    auto test_file = test[i];
    status = reader.find(test_file.name(), &ar_file);
    if (status != 0) FATAL("Ar File not found");
    if (strcmp(ar_file.name(), test_file.name()) != 0) FATAL("Not using given name");
  }
}

int main(int argc, char** argv) {
  ar::File even_file(
    "even", ar::AR_DONT_FREE,
    unsigned_cast("even"), ar::AR_DONT_FREE,
    4);
  ar::File odd_file(
    "odd", ar::AR_DONT_FREE,
    unsigned_cast("odd"), ar::AR_DONT_FREE,
    3);
  ar::File binary(
    "binary", ar::AR_DONT_FREE,
    unsigned_cast("\x00\x01\x02"), ar::AR_DONT_FREE,
    3);
  ar::File new_lines(
    "new_lines", ar::AR_DONT_FREE,
    unsigned_cast("\n\n\n\a\a\a"), ar::AR_DONT_FREE,
    6);

  std::vector<List<ar::File>> tests = {
    List<ar::File>(),
    ListBuilder<ar::File>::build(even_file),
    ListBuilder<ar::File>::build(odd_file),
    ListBuilder<ar::File>::build(even_file, odd_file),
    ListBuilder<ar::File>::build(odd_file, even_file),
    ListBuilder<ar::File>::build(binary),
    ListBuilder<ar::File>::build(new_lines),
    ListBuilder<ar::File>::build(even_file, odd_file, binary),
  };

  char tmp_dir_buffer[PATH_MAX];
  strncpy(tmp_dir_buffer, "/tmp/ar_read_test-XXXXXX", PATH_MAX);
  tmp_dir_buffer[PATH_MAX - 1] = '\0';
  const char* tmp_dir = mkdtemp(tmp_dir_buffer);
  if (tmp_dir == null) FATAL("Couldn't create temporary directory");
  char test_path[PATH_MAX];
  snprintf(test_path, PATH_MAX, "%s/test.a", tmp_dir);
  for (auto test : tests) {
    ar::FileBuilder file_builder;
    ar::MemoryBuilder memory_builder;
    int status = file_builder.open(test_path);
    if (status != 0) FATAL("Couldn't open file");
    status = memory_builder.open();
    if (status != 0) FATAL("Couldn't allocate memory");
    for (auto file : test) {
      status = file_builder.add(file);
      if (status != 0) FATAL("Couldn't write to file");
      status = memory_builder.add(file);
      if (status != 0) FATAL("Couldn't allocate memory");
    }
    status = file_builder.close();
    if (status != 0) FATAL("Couldn't close file");
    uint8* buffer;
    int size;
    memory_builder.close(&buffer, &size);

    ar::FileReader file_reader;
    status = file_reader.open(test_path);
    if (status != 0) FATAL("Error while opening file reader");
    do_test(test, file_reader);
    status = file_reader.close();
    if (status != 0) FATAL("Error while closing file reader");

    ar::MemoryReader memory_reader(buffer, size);
    do_test(test, memory_reader);

    status = unlink(test_path);
    if (status != 0) FATAL("Couldn't delete file");
    free(buffer);
  }
  rmdir(tmp_dir);
  return 0;
}

}

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  return toit::main(argc, argv);
}

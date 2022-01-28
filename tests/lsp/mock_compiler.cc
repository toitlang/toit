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

#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#include "../../src/top.h"
#include "../../src/compiler/tar.h"
#include "../../src/compiler/lsp/fs_connection_socket.h"
#include "../../src/compiler/lsp/fs_protocol.h"
#include "../../src/compiler/lsp/multiplex_stdout.h"
#include "../../src/compiler/lsp/protocol.h"
#include "../../src/compiler/filesystem_lsp.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/package.h"

#ifdef TOIT_WINDOWS
// Make the mock-compiler compile on Windows.
// Clearly doesn't work yet.
size_t getline (char** line_ptr,
                size_t* n,
                FILE* stream) {
  UNIMPLEMENTED();
}
#define SIGKILL 9
#endif

using namespace toit::compiler;
using namespace toit;

namespace toit {

unsigned int checksum[4] = { 0, 0, 0, 0};

}  // namespace toit

static bool starts_with(const uint8* str, const char* prefix) {
  return strncmp(char_cast(str), prefix, strlen(prefix)) == 0;
}

char* read_line() {
  size_t line_size = 0;
  char* result = null;
  ssize_t read_chars = getline(&result, &line_size, stdin);
  if (read_chars == -1) FATAL("Couldn't read line");
  result[strlen(result) - 1] = '\0';  // Remove the trailing \n.
  return result;
}

void writer_printf(LspWriter* writer, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  writer->printf(format, arguments);
  va_end(arguments);
}

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  const char* MOCK_PREFIX = "///mock:";

  const char* port = read_line();

  const char* command = read_line();

  const char* path = null;

  if (strcmp(command, "ANALYZE") == 0) {
    int path_count = atoi(read_line());
    // We only care for the first one, but will read all the remaining ones.
    ASSERT(path_count > 0);
    path = read_line();
    for (int i = 1; i < path_count; i++) read_line();
  } else {
    path = read_line();
    if (strcmp(command, "DUMP_FILE_NAMES") == 0) {
      // No need to read more.
    }
    if (strcmp(command, "COMPLETE") == 0 ||
        strcmp(command, "GOTO DEFINITION") == 0) {
      // Read two lines. One for the line number, one for the column number.
      for (int i = 0; i < 2; i++) {
        char* ignored_line = read_line();
        free(ignored_line);
      }
    }
  }

  LspFsConnection* connection = null;
  LspWriter* writer;
  if (strcmp("-2", port) == 0) {
    // Multiplex the FS protocol and the LSP output over stdout/stdin.
    connection = _new LspFsConnectionMultiplexStdout();
    writer = _new LspWriterMultiplexStdout();
  } else {
    // Communicate over a socket for the filesystem, and over stdout
    // for the LSP output.
    connection = _new LspFsConnectionSocket(port);
    writer = new LspWriterStdout();
  }

  LspFsProtocol fs_protocol(connection);
  FilesystemLsp fs(&fs_protocol);
  SourceManager manager(&fs);
  NullDiagnostics diagnostics(&manager);
  fs.initialize(&diagnostics);

  // Ignore mock updates.
  if (starts_with(unsigned_cast(path), MOCK_PREFIX)) return 0;  // Just ignore it.

  auto mock_path = std::string(MOCK_PREFIX) + command;

  auto load_result = manager.load_file(mock_path, Package::invalid());
  if (load_result.status != SourceManager::LoadResult::OK) {
    // No response.
    return 0;
  }

  const uint8* text = load_result.source->text();

  bool should_crash = false;
  bool should_timeout = false;
  if (starts_with(text, "CRASH\n")) {
    should_crash = true;
    text += strlen("CRASH\n");
  }
  if (starts_with(text, "TIMEOUT\n")) {
    should_timeout = true;
    text += strlen("TIMEOUT\n");
  }
  if (starts_with(text, "SLOW\n")) {
    text += strlen("SLOW\n");
    int amount = atoi(char_cast(text));
    fprintf(stderr, "Simulating slow compiler %d\n", amount);
    while (*text != '\n') text++;
    text++; // Skip over the '\n'.
    usleep(amount);
  }

  writer_printf(writer, "%s", text);

  if (should_crash) {
    fprintf(stderr, "Simulating compiler crash\n");
    // We use SIGKILL, since that one doesn't create core dumps.
    raise(SIGKILL);
  }
  if (should_timeout) {
    fprintf(stderr, "Simulating timeout\n");
    sleep(15);
  }
  return 0;
}

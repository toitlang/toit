// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>

#include <string>

#include "../../src/top.h"
#include "../../src/compiler/lsp/fs_connection_socket.h"
#include "../../src/compiler/lsp/fs_protocol.h"
#include "../../src/compiler/lsp/multiplex_stdout.h"
#include "../../src/compiler/lsp/protocol.h"
#include "../../src/compiler/filesystem_lsp.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/package.h"

#ifdef TOIT_WINDOWS
#include <process.h>
#define getpid _getpid

// https://stackoverflow.com/a/47229318
// /* The original code is public domain -- Will Hartung 4/9/09 */
// /* Modifications, public domain as well, by Antti Haapala, 11/10/17
//    - Switched to getc on 5/23/19 */
// Slightly modified (floitsch):
//  - avoid warnings with malloc (using 'unvoid_cast').
//  - indentation.
//  - discard trailing '\r'.
//  - formatting ('*' binds to type).
//  - made the function static.
//  - use 'null' instead of 'NULL'.
//  - use `reinterpret_cast` instead of C cast.
static ssize_t getline(char** lineptr, size_t* n, FILE* stream) {
  size_t pos;
  int c;

  if (lineptr == null || stream == null || n == null) {
    errno = EINVAL;
    return -1;
  }

  c = getc(stream);
  if (c == EOF) {
    return -1;
  }

  if (*lineptr == null) {
    *lineptr = toit::unvoid_cast<char*>(malloc(128));
    if (*lineptr == null) {
      return -1;
    }
    *n = 128;
  }

  pos = 0;
  while(c != EOF) {
    if (pos + 1 >= *n) {
      size_t new_size = *n + (*n >> 2);
      if (new_size < 128) {
        new_size = 128;
      }
      char* new_ptr = toit::unvoid_cast<char*>(realloc(*lineptr, new_size));
      if (new_ptr == null) {
        return -1;
      }
      *n = new_size;
      *lineptr = new_ptr;
    }

    reinterpret_cast<unsigned char*>(*lineptr)[pos ++] = c;
    if (c == '\n') {
      break;
    }
    c = getc(stream);
  }

  if (pos != 0 && (*lineptr)[pos - 1] == '\r') {
    pos --;
  }
  (*lineptr)[pos] = '\0';
  return pos;
}
#define SIGCRASH SIGILL
#else
// We use SIGKILL, since that one doesn't create core dumps.
#define SIGCRASH SIGKILL
#endif

using namespace toit::compiler;
using namespace toit;

// The test listens on this port for mock compilers. See mock-compiler.toit.
static const char* CONTROL_PORT_ENV = "TOIT_MOCK_COMPILER_PORT";

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
#ifdef TOIT_WINDOWS
  // On Windows, we need to set the stdout to binary mode.
  // Otherwise, any '\n' we print becomes '\r\n'.
  setmode(fileno(stdout), O_BINARY);
  setmode(fileno(stdin), O_BINARY);
  setmode(fileno(stderr), O_BINARY);
#endif
  toit::throwing_new_allowed = true;

  const char* port = read_line();

  const char* command = read_line();

  // The request as the server sent it. It is forwarded to the test.
  std::string request = command;
  const char* path = null;

  if (strcmp(command, "ANALYZE") == 0) {
    char* count_line = read_line();
    request += std::string("\n") + count_line;
    int path_count = atoi(count_line);
    ASSERT(path_count > 0);
    for (int i = 0; i < path_count; i++) {
      char* line = read_line();
      request += std::string("\n") + line;
      if (i == 0) path = line;
    }
  } else {
    path = read_line();
    request += std::string("\n") + path;
    if (strcmp(command, "COMPLETE") == 0 ||
        strcmp(command, "GOTO DEFINITION") == 0) {
      // Read two lines. One for the line number, one for the column number.
      for (int i = 0; i < 2; i++) {
        char* line = read_line();
        request += std::string("\n") + line;
      }
    }
  }

  const char* control_port = getenv(CONTROL_PORT_ENV);
  if (control_port == null) FATAL("%s is not set", CONTROL_PORT_ENV);

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

  // Announce this run to the test. The test answers with the output this
  // run should produce, and may hold the answer back to keep the run waiting.
  LspFsConnectionSocket control(control_port);
  control.initialize(&diagnostics);
  control.putline(std::to_string(getpid()).c_str());
  control.putline(request.c_str());
  control.putline("");  // End of the request.

  // Load the requested file, so that the file server sees the same
  // requests as with a real compiler. The content is irrelevant.
  manager.load_file(path, Package::invalid());

  char* size_line = control.getline();
  int size = atoi(size_line);
  free(size_line);
  uint8* answer = unvoid_cast<uint8*>(malloc(size + 1));
  if (control.read_data(answer, size) != 0) FATAL("Couldn't read answer");
  answer[size] = '\0';
  const uint8* text = answer;

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
  writer_printf(writer, "%s", text);

  if (should_crash) {
    fprintf(stderr, "Simulating compiler crash\n");
    raise(SIGCRASH);
  }
  if (should_timeout) {
    fprintf(stderr, "Simulating timeout\n");
    sleep(15);
  }
  return 0;
}

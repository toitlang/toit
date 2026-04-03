// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../src/top.h"
#include "../../src/compiler/windows.h"

namespace toit {

// Helper: create a FILE* backed by a temporary file with the given content.
static FILE* make_stream(const char* content, size_t length) {
  FILE* f = tmpfile();
  if (f == NULL) FATAL("tmpfile() failed");
  if (fwrite(content, 1, length, f) != length) FATAL("fwrite failed");
  rewind(f);
  return f;
}

static void test_simple_line() {
  const char* input = "hello\n";
  FILE* f = make_stream(input, strlen(input));

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != 6) FATAL("expected 6, got %zd", (ssize_t)result);
  if (strcmp(line, "hello\n") != 0) FATAL("unexpected content: '%s'", line);
  if (n < 6) FATAL("buffer too small: %zd", (ssize_t)n);

  free(line);
  fclose(f);
}

static void test_line_without_newline() {
  // EOF without a trailing newline.
  const char* input = "no newline";
  FILE* f = make_stream(input, strlen(input));

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != 10) FATAL("expected 10, got %zd", (ssize_t)result);
  if (strcmp(line, "no newline") != 0) FATAL("unexpected content: '%s'", line);

  free(line);
  fclose(f);
}

static void test_empty_stream() {
  FILE* f = make_stream("", 0);

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  // EOF on first read should return (size_t)-1.
  if (result != (size_t)-1) FATAL("expected -1 on empty stream, got %zd", (ssize_t)result);

  free(line);
  fclose(f);
}

static void test_multiple_lines() {
  const char* input = "first\nsecond\nthird\n";
  FILE* f = make_stream(input, strlen(input));

  char* line = NULL;
  size_t n = 0;

  size_t result = toit_getline(&line, &n, f);
  if (result != 6) FATAL("line 1: expected 6, got %zd", (ssize_t)result);
  if (strcmp(line, "first\n") != 0) FATAL("line 1: unexpected '%s'", line);

  result = toit_getline(&line, &n, f);
  if (result != 7) FATAL("line 2: expected 7, got %zd", (ssize_t)result);
  if (strcmp(line, "second\n") != 0) FATAL("line 2: unexpected '%s'", line);

  result = toit_getline(&line, &n, f);
  if (result != 6) FATAL("line 3: expected 6, got %zd", (ssize_t)result);
  if (strcmp(line, "third\n") != 0) FATAL("line 3: unexpected '%s'", line);

  // EOF.
  result = toit_getline(&line, &n, f);
  if (result != (size_t)-1) FATAL("expected -1 at EOF, got %zd", (ssize_t)result);

  free(line);
  fclose(f);
}

static void test_buffer_reuse() {
  // When called with an existing buffer, getline should reuse it.
  char* line = reinterpret_cast<char*>(malloc(64));
  if (line == NULL) FATAL("malloc failed");
  size_t n = 64;

  const char* input = "short\n";
  FILE* f = make_stream(input, strlen(input));

  size_t result = toit_getline(&line, &n, f);
  if (result != 6) FATAL("expected 6, got %zd", (ssize_t)result);
  if (strcmp(line, "short\n") != 0) FATAL("unexpected content: '%s'", line);
  // Buffer should still be at least 64 bytes (not shrunk).
  if (n < 64) FATAL("buffer shrank: %zd", (ssize_t)n);

  free(line);
  fclose(f);
}

// This is the critical test: lines longer than 127 characters require the
// buffer to grow beyond the initial 128-byte allocation. The original
// implementation had a use-after-free here because the write pointer was
// not updated after realloc.
static void test_long_line_triggers_realloc() {
  // Build a line of exactly 200 characters + newline.
  const int content_length = 200;
  char input[content_length + 2];  // +1 newline, +1 NUL for construction.
  for (int i = 0; i < content_length; i++) {
    input[i] = 'A' + (i % 26);
  }
  input[content_length] = '\n';
  input[content_length + 1] = '\0';

  FILE* f = make_stream(input, content_length + 1);

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != (size_t)(content_length + 1)) {
    FATAL("expected %d, got %zd", content_length + 1, (ssize_t)result);
  }
  if (memcmp(line, input, content_length + 1) != 0) {
    FATAL("content mismatch on long line");
  }
  // Buffer must have grown beyond 128.
  if (n <= 128) FATAL("buffer did not grow: %zd", (ssize_t)n);

  free(line);
  fclose(f);
}

// Test the exact boundary: 127 content chars + newline = 128 bytes.
// The old code had an off-by-one where the null terminator wrote past the end.
static void test_exact_boundary_128() {
  const int content_length = 127;
  char input[content_length + 2];
  for (int i = 0; i < content_length; i++) {
    input[i] = '0' + (i % 10);
  }
  input[content_length] = '\n';
  input[content_length + 1] = '\0';

  FILE* f = make_stream(input, content_length + 1);

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != (size_t)(content_length + 1)) {
    FATAL("expected %d, got %zd", content_length + 1, (ssize_t)result);
  }
  if (memcmp(line, input, content_length + 1) != 0) {
    FATAL("content mismatch at 128-byte boundary");
  }

  free(line);
  fclose(f);
}

// Test a line that spans multiple realloc growth steps (> 256 bytes).
static void test_very_long_line() {
  const int content_length = 500;
  char input[content_length + 2];
  for (int i = 0; i < content_length; i++) {
    input[i] = '!' + (i % 94);  // Printable ASCII range.
  }
  input[content_length] = '\n';
  input[content_length + 1] = '\0';

  FILE* f = make_stream(input, content_length + 1);

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != (size_t)(content_length + 1)) {
    FATAL("expected %d, got %zd", content_length + 1, (ssize_t)result);
  }
  if (memcmp(line, input, content_length + 1) != 0) {
    FATAL("content mismatch on very long line");
  }
  // Must have grown through multiple realloc steps.
  if (n < (size_t)(content_length + 1)) {
    FATAL("buffer too small for content: %zd", (ssize_t)n);
  }

  free(line);
  fclose(f);
}

static void test_single_newline() {
  const char* input = "\n";
  FILE* f = make_stream(input, 1);

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != 1) FATAL("expected 1, got %zd", (ssize_t)result);
  if (line[0] != '\n') FATAL("expected newline char");

  free(line);
  fclose(f);
}

static void test_single_char() {
  const char* input = "x";
  FILE* f = make_stream(input, 1);

  char* line = NULL;
  size_t n = 0;
  size_t result = toit_getline(&line, &n, f);
  if (result != 1) FATAL("expected 1, got %zd", (ssize_t)result);
  if (line[0] != 'x') FATAL("expected 'x'");
  if (line[1] != '\0') FATAL("expected null terminator");

  free(line);
  fclose(f);
}

static void test_null_args() {
  FILE* f = make_stream("x\n", 2);
  char* line = NULL;
  size_t n = 0;

  // NULL lineptr.
  size_t result = toit_getline(NULL, &n, f);
  if (result != (size_t)-1) FATAL("expected -1 for NULL lineptr");

  // NULL n.
  result = toit_getline(&line, NULL, f);
  if (result != (size_t)-1) FATAL("expected -1 for NULL n");

  // NULL stream.
  result = toit_getline(&line, &n, NULL);
  if (result != (size_t)-1) FATAL("expected -1 for NULL stream");

  free(line);
  fclose(f);
}

int main(int argc, char** argv) {
  test_simple_line();
  test_line_without_newline();
  test_empty_stream();
  test_multiple_lines();
  test_buffer_reuse();
  test_long_line_triggers_realloc();
  test_exact_boundary_128();
  test_very_long_line();
  test_single_newline();
  test_single_char();
  test_null_args();
  printf("All getline tests passed.\n");
  return 0;
}

}  // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}

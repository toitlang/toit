// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <cstdio>
#include <string>

#include "../../src/compiler/lsp/multiplex_stdout.h"

#ifdef TOIT_POSIX
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

namespace toit {

// Run the stdin-based reader in a child so a rejected line cannot abort the
// test runner. Check its diagnostic, not just its exit status: an unchecked
// memory access or sanitizer failure must not count as successful rejection.
static void check_line(const char* input, int size, const char* expected) {
  FILE* file = tmpfile();
  if (file == null) FATAL("Couldn't create input file");
  if (fwrite(input, 1, size, file) != static_cast<size_t>(size)) FATAL("Couldn't write input");
  rewind(file);
  int errors[2];
  if (pipe(errors) != 0) FATAL("Couldn't create diagnostic pipe");
  auto pid = fork();
  if (pid < 0) FATAL("Couldn't fork line reader");
  if (pid == 0) {
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) != 0) _exit(2);
    close(errors[0]);
    if (dup2(fileno(file), STDIN_FILENO) < 0 || dup2(errors[1], STDERR_FILENO) < 0) _exit(2);
    close(errors[1]);
    fclose(file);
    compiler::LspFsConnectionMultiplexStdout connection;
    char* line = connection.getline();
    bool matches = expected != null && strcmp(line, expected) == 0;
    free(line);
    _exit(matches ? 0 : 2);
  }
  fclose(file);
  close(errors[1]);
  std::string diagnostic;
  char buffer[1024];
  ssize_t count;
  while ((count = read(errors[0], buffer, sizeof(buffer))) > 0) {
    diagnostic.append(buffer, count);
  }
  close(errors[0]);
  int status;
  if (waitpid(pid, &status, 0) != pid) FATAL("Couldn't wait for line reader");
  if (expected != null) {
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) FATAL("Valid line rejected");
  } else {
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) FATAL("Invalid line accepted");
    if (diagnostic.find("Invalid filesystem response line") == std::string::npos ||
        diagnostic.find("AddressSanitizer") != std::string::npos) {
      FATAL("Invalid line was not safely rejected: %s", diagnostic.c_str());
    }
  }
}

static void test() {
  AllowThrowingNew allow;
  check_line("\n", 1, "");
  check_line("value\n", 6, "value");
  check_line("\0\n", 2, null);
  check_line("part\0rest\n", 10, null);
  check_line("unterminated", 12, null);
}

} // namespace toit
#endif

int main(int argc, char** argv) {
#ifdef TOIT_POSIX
  toit::test();
#endif
  return 0;
}

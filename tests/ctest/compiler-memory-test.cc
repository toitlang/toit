// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/compiler/compiler.h"
#include "../../src/compiler/filesystem_lsp.h"
#include "../../src/flags.h"
#include "../../src/os.h"
#include "../../src/snapshot.h"

namespace toit {

// Exercise the socket protocol's ownership contract without a live server.
class MemoryConnection : public compiler::LspFsConnection {
 public:
  void initialize(compiler::Diagnostics* diagnostics) {}
  void putline(const char* line) {}
  char* getline() {
    const char* lines[] = {"/sdk", "2", "/cache/one", "/cache/two",
                          "true", "true", "false", "6"};
    if (next_ == ARRAY_SIZE(lines)) FATAL("Unexpected filesystem request");
    return strdup(lines[next_++]);
  }
  int read_data(uint8* content, int size) {
    if (size != 6 || reads_++ != 0) FATAL("Unexpected content request");
    memcpy(content, "hello\n", size);
    return 0;
  }
 private:
  unsigned next_ = 0;
  int reads_ = 0;
};

static void test_lsp_filesystem() {
  compiler::Zone zone;
  MemoryConnection connection;
  compiler::LspFsProtocol protocol(&connection);
  compiler::FilesystemLsp fs(&protocol);
  if (strcmp(fs.sdk_path(), "/sdk") != 0) FATAL("Wrong SDK path");
  auto paths = fs.package_cache_paths();
  if (paths.length() != 2 || strcmp(paths[1], "/cache/two") != 0) FATAL("Wrong cache paths");
  if (!fs.exists("/test.toit") || !fs.is_regular_file("/test.toit")) FATAL("Missing file");
  int size;
  auto content = fs.read_content("/test.toit", &size);
  if (size != 6 || strcmp(char_cast(content), "hello\n") != 0) FATAL("Wrong file content");
  if (fs.read_content("/test.toit", &size) != content) FATAL("Content was not cached");
  // Intercepted content is borrowed, even when cached content is owned.
  fs.register_intercepted("/intercepted", unsigned_cast("static"), 6);
  if (strcmp(char_cast(fs.read_content("/intercepted", &size)), "static") != 0) {
    FATAL("Wrong intercepted content");
  }
}

static void test() {
  OS::set_up();
  Flags::no_fork = true;
  {
    compiler::Compiler compiler;
    test_lsp_filesystem();
    compiler::Compiler::Configuration config = {};
    // Reuse the same compiler, exercising both one- and two-pass compilation.
    // Sanitizers must see each compilation release its memory on return.
    for (int i = 0; i < 6; i++) {
      config.optimization_level = i % 3;
      auto bundle = compiler.compile(null, "1_000 + 2", null, config);
      if (!bundle.is_valid()) FATAL("Compilation failed");
      // The bundle is caller-owned and must survive destruction of the zone.
      auto snapshot = bundle.snapshot();
      if (snapshot.size() <= 0) FATAL("Empty snapshot");
      uint8 uuid[16];
      if (!bundle.uuid(uuid)) FATAL("Invalid snapshot bundle");
      auto stripped = bundle.stripped();
      if (!stripped.is_valid()) FATAL("Could not strip snapshot");
      free(stripped.buffer());
      free(bundle.buffer());
    }
  }
  OS::tear_down();
}

} // namespace toit

int main(int argc, char** argv) {
  toit::test();
  return 0;
}

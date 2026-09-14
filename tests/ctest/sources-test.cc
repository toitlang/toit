// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <cstring>

#include "../../src/top.h"
#include "../../src/utils.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/sources.h"

namespace toit {
namespace compiler {

static void fatal(int line) {
  FATAL("FATAL at line %d", line);
}

static Source* load(SourceManager* manager, FilesystemLocal* fs, const char* path, const char* content) {
  fs->register_intercepted(path, unsigned_cast(content), strlen(content));
  auto result = manager->load_file(path, Package::invalid());
  if (result.status != SourceManager::LoadResult::OK) FATAL("couldn't load %s", path);
  return result.source;
}

static Source::Position pos(Source* source, int offset) {
  return source->range(offset, offset).from();
}

// Checks the location of [offset] in [source]. [column] is 0-based.
static void check(int line, SourceManager* manager, Source* source, int offset,
                  int expected_line, int expected_column) {
  auto location = manager->compute_location(pos(source, offset));
  if (location.source != source ||
      location.offset_in_source != offset ||
      location.line_number != expected_line ||
      location.offset_in_line != expected_column ||
      location.line_offset != offset - expected_column) {
    FATAL("FATAL at line %d: got %s %d:%d", line,
          location.source->absolute_path(), location.line_number, location.offset_in_line);
  }
}

#define CHECK(source, offset, line, column) check(__LINE__, &manager, source, offset, line, column)
#define CHECK_SOURCE(source, offset) \
  if (manager.source_for_position(pos(source, offset)) != source) fatal(__LINE__)

static void test_lf() {
  FilesystemLocal fs;
  SourceManager manager(&fs);
  auto s = load(&manager, &fs, "/lf.toit", "ab\ncd\n\nx");
  CHECK(s, 0, 1, 0);
  CHECK(s, 2, 1, 2);  // The '\n' belongs to its line.
  CHECK(s, 3, 2, 0);
  CHECK(s, 5, 2, 2);
  CHECK(s, 6, 3, 0);  // Empty line.
  CHECK(s, 7, 4, 0);
  CHECK(s, 8, 4, 1);  // End of file.
  // Queries going backwards.
  CHECK(s, 3, 2, 0);
  CHECK(s, 0, 1, 0);
}

static void test_cr() {
  FilesystemLocal fs;
  SourceManager manager(&fs);
  auto s = load(&manager, &fs, "/crlf.toit", "a\r\nb\rc\r\n\r\nd\r");
  CHECK(s, 1, 1, 1);   // '\r' of "\r\n".
  CHECK(s, 2, 1, 2);   // '\n' of "\r\n" belongs to its line.
  CHECK(s, 3, 2, 0);
  CHECK(s, 4, 2, 1);   // A lone '\r' doesn't end a line.
  CHECK(s, 5, 2, 2);
  CHECK(s, 8, 3, 0);
  CHECK(s, 10, 4, 0);
  CHECK(s, 11, 4, 1);  // Trailing lone '\r'.
  CHECK(s, 12, 4, 2);  // End of file.
  CHECK(s, 3, 2, 0);
}

static void test_empty() {
  FilesystemLocal fs;
  SourceManager manager(&fs);
  auto s = load(&manager, &fs, "/empty.toit", "");
  CHECK(s, 0, 1, 0);
}

static void test_multiple_sources() {
  FilesystemLocal fs;
  SourceManager manager(&fs);
  auto a = load(&manager, &fs, "/a.toit", "a\nb");
  auto empty = load(&manager, &fs, "/empty.toit", "");
  auto c = load(&manager, &fs, "/c.toit", "\ncc");
  auto d = load(&manager, &fs, "/d.toit", "d\n");
  if (load(&manager, &fs, "/a.toit", "ignored") != a) fatal(__LINE__);
  // Boundaries between sources, in both directions.
  CHECK(a, 3, 2, 1);
  CHECK(empty, 0, 1, 0);
  CHECK(c, 0, 1, 0);
  CHECK(empty, 0, 1, 0);
  CHECK(a, 3, 2, 1);
  CHECK(d, 2, 2, 0);
  CHECK(a, 0, 1, 0);
  CHECK(c, 3, 2, 2);
  CHECK(d, 0, 1, 0);
  CHECK(c, 1, 2, 0);
  CHECK_SOURCE(a, 0);
  CHECK_SOURCE(a, 3);
  CHECK_SOURCE(empty, 0);
  CHECK_SOURCE(c, 0);
  CHECK_SOURCE(c, 3);
  CHECK_SOURCE(d, 0);
  CHECK_SOURCE(d, 2);
  CHECK_SOURCE(a, 1);
}

int main(int argc, char** argv) {
  AllowThrowingNew allow;
  test_lf();
  test_cr();
  test_empty();
  test_multiple_sources();
  return 0;
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  return toit::compiler::main(argc, argv);
}

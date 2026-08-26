// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <string>

#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_verifier.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-support.h"

namespace toit {
namespace compiler {

static bool verify(const std::string& original,
                   const std::string& formatted) {
  FilesystemLocal filesystem;
  SourceManager sources(&filesystem);
  Source* source = sources.load_from_memory(
      "///<format-verifier-original>",
      reinterpret_cast<const uint8*>(original.data()),
      original.size());
  SymbolCanonicalizer symbols;
  NullDiagnostics diagnostics(&sources);
  Scanner scanner(source, &symbols, &diagnostics);
  Parser parser(source, &scanner, &diagnostics);
  ast::Unit* unit = parser.parse_unit();
  ASSERT(!diagnostics.encountered_error());

  return verify_formatted_output(
      &sources,
      source,
      &scanner,
      unit,
      reinterpret_cast<const uint8*>(formatted.data()),
      formatted.size(),
      "<format-verifier-test>");
}

static void test_format_verifier() {
  ASSERT(verify(
      "main: return ((1 + 2))  // Keep this.\n",
      "main:\n  return 1 + 2  // Keep this.\n"));

  ASSERT(verify(
      "main:\n  /* First line.\n     Second line. */\n  return 1\n",
      "main:\n    /* First line.\n       Second line. */\n    return 1\n"));

  ASSERT(!verify(
      "main: return 1  // Keep this.\n",
      "main: return 1\n"));

  ASSERT(!verify(
      "main: return 1  // Keep this.\n",
      "main:\n  // Keep this.\n  return 1\n"));

  ASSERT(!verify("main: return 1 + 2\n", "main: return 1 * 2\n"));
  ASSERT(!verify("main: return Foo.bar\n", "main: return (Foo).bar\n"));
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);
  toit::compiler::test_format_verifier();
  return 0;
}

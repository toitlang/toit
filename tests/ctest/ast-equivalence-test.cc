// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <memory>
#include <string>

#include "../../src/compiler/ast_equivalence.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"

namespace toit {
namespace compiler {

struct ParsedUnit {
  std::unique_ptr<SymbolCanonicalizer> symbols;
  ast::Unit* unit = null;
};

static ParsedUnit parse(SourceManager* sources,
                        const char* path,
                        const std::string& text) {
  static int next_source_id = 0;
  ParsedUnit result;
  result.symbols.reset(new SymbolCanonicalizer());
  std::string unique_path = std::string(path) + std::to_string(next_source_id++);
  Source* source = sources->load_from_memory(
      unique_path,
      reinterpret_cast<const uint8*>(text.data()),
      text.size());
  NullDiagnostics diagnostics(sources);
  Scanner scanner(source, result.symbols.get(), &diagnostics);
  Parser parser(source, &scanner, &diagnostics);
  result.unit = parser.parse_unit();
  ASSERT(!diagnostics.encountered_error());
  return result;
}

static void expect_equivalent(SourceManager* sources,
                              const std::string& left,
                              const std::string& right) {
  ParsedUnit left_unit = parse(sources, "///<ast-equivalence-left>", left);
  ParsedUnit right_unit = parse(sources, "///<ast-equivalence-right>", right);
  ASSERT(ast_equivalent(left_unit.unit, right_unit.unit));
}

static void expect_different(SourceManager* sources,
                             const std::string& left,
                             const std::string& right) {
  ParsedUnit left_unit = parse(sources, "///<ast-difference-left>", left);
  ParsedUnit right_unit = parse(sources, "///<ast-difference-right>", right);
  ast::Node* mismatch_left = null;
  ast::Node* mismatch_right = null;
  ASSERT(!ast_equivalent(left_unit.unit,
                         right_unit.unit,
                         &mismatch_left,
                         &mismatch_right));
  ASSERT(mismatch_left != null || mismatch_right != null);
}

static void test_ast_equivalence(SourceManager* sources) {
  expect_equivalent(
      sources,
      "main: return ((1 + 2))\n",
      "main:\n  return 1 + 2\n");

  expect_equivalent(
      sources,
      "compute first second -> int: return first + second\n",
      "compute -> int\n    first\n    second\n:\n  return first + second\n");

  expect_different(
      sources,
      "main: return 1 + 2\n",
      "main: return 1 * 2\n");

  // Parentheses around a possible static receiver are resolver-sensitive.
  expect_different(
      sources,
      "main: return Foo.bar\n",
      "main: return (Foo).bar\n");
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);

  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::test_ast_equivalence(&sources);
  return 0;
}

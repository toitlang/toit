// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <memory>
#include <string>

#include "../../src/compiler/ast_equivalence.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_statement.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-support.h"

namespace toit {
namespace compiler {

struct ParsedBody {
  std::unique_ptr<SymbolCanonicalizer> symbols;
  Source* source = null;
  ast::Sequence* body = null;
};

static ParsedBody parse_body(SourceManager* sources, const std::string& body) {
  static int next_source_id = 0;
  ParsedBody result;
  result.symbols.reset(new SymbolCanonicalizer());
  std::string program = "sample:\n" + body + "\n";
  std::string path = "///<format-statement-" +
      std::to_string(next_source_id++) + ">";
  result.source = sources->load_from_memory(
      path,
      reinterpret_cast<const uint8*>(program.data()),
      program.size());
  NullDiagnostics diagnostics(sources);
  Scanner scanner(result.source, result.symbols.get(), &diagnostics);
  Parser parser(result.source, &scanner, &diagnostics);
  ast::Unit* unit = parser.parse_unit();
  ASSERT(!diagnostics.encountered_error());
  result.body = unit->declarations()[0]->as_Method()->body();
  ASSERT(result.body != null);
  return result;
}

static std::string format(SourceManager* sources,
                          const std::string& input,
                          int preferred_extent = 100) {
  ParsedBody parsed = parse_body(sources, input);
  FormatStyle style;
  style.preferred_extent = preferred_extent;
  style.indentation_pressure_divisor = 0;
  std::string output;
  ASSERT(format_sequence(parsed.body, parsed.source, 2, &output, style));

  ParsedBody reparsed = parse_body(sources, output);
  ASSERT(ast_nodes_equivalent(parsed.body, reparsed.body));
  std::string second;
  ASSERT(format_sequence(
      reparsed.body, reparsed.source, 2, &second, style));
  ASSERT(second == output);
  return output;
}

static void test_format_statement(SourceManager* sources) {
  ASSERT(format(sources, "  value  :=  1\n  return  value") ==
      "  value := 1\n  return value");
  ASSERT(format(sources, "  if ready: return 1\n  else: return 2") ==
      "  if ready:\n    return 1\n  else:\n    return 2");
  ASSERT(format(sources, "  while ready: continue") ==
      "  while ready:\n    continue");
  ASSERT(format(sources, "  for i := 0; i < 3; i++: print i") ==
      "  for i := 0; i < 3; i++:\n    print i");
  ASSERT(format(sources, "  try: work\n  finally: cleanup") ==
      "  try:\n    work\n  finally:\n    cleanup");
  ASSERT(format(
      sources,
      "  return alpha-long + beta-long + gamma-long",
      15) ==
      "  return alpha-long\n"
      "      + beta-long\n"
      "      + gamma-long");
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);
  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::test_format_statement(&sources);
  return 0;
}

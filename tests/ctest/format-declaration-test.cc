// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <memory>
#include <string>

#include "../../src/compiler/ast_equivalence.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_declaration.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"

namespace toit {
namespace compiler {

struct ParsedMethod {
  std::unique_ptr<SymbolCanonicalizer> symbols;
  Source* source = null;
  ast::Method* method = null;
};

static ParsedMethod parse_method(SourceManager* sources,
                                 const std::string& header) {
  static int next_source_id = 0;
  ParsedMethod result;
  result.symbols.reset(new SymbolCanonicalizer());
  std::string program = header + "\n  return 0\n";
  std::string path = "///<format-declaration-" +
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
  ASSERT(unit->declarations().length() == 1);
  result.method = unit->declarations()[0]->as_Method();
  ASSERT(result.method != null);
  return result;
}

static std::string format(SourceManager* sources,
                          const std::string& input,
                          int preferred_extent = 100) {
  ParsedMethod parsed = parse_method(sources, input);
  FormatStyle style;
  style.preferred_extent = preferred_extent;
  style.indentation_pressure_divisor = 0;
  FormatOutput output_lines;
  ASSERT(format_method_header(
      parsed.method, parsed.source, 0, &output_lines, style));
  std::string output = output_lines.render(0);

  ParsedMethod reparsed = parse_method(sources, output);
  ASSERT(ast_nodes_equivalent(parsed.method, reparsed.method));
  FormatOutput second_output;
  ASSERT(format_method_header(
      reparsed.method, reparsed.source, 0, &second_output, style));
  ASSERT(second_output.render(0) == output);
  return output;
}

static void test_format_method_header(SourceManager* sources) {
  ASSERT(format(sources, "short x/int y/int -> int:") ==
      "short x/int y/int -> int:");
  ASSERT(format(
      sources,
      "configure --organization/string --application/string value/int -> bool:",
      30) ==
      "configure -> bool\n"
      "    --organization/string\n"
      "    --application/string\n"
      "    value/int\n"
      ":");
  ASSERT(format(
      sources,
      "other x/int y/int --extra/int=0 -> int:",
      26) ==
      "other x/int y/int -> int\n"
      "    --extra/int=0\n"
      ":");
  ASSERT(format(sources, "each items/List [--handler] -> none:") ==
      "each items/List [--handler] -> none:");
  ASSERT(format(sources, "static set-value= value/int -> none:") ==
      "static set-value= value/int -> none:");
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);
  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::test_format_method_header(&sources);
  return 0;
}

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <memory>
#include <string>

#include "../../src/compiler/ast_equivalence.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_unit.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"

namespace toit {
namespace compiler {

struct ParsedUnit {
  std::unique_ptr<SymbolCanonicalizer> symbols;
  Source* source = null;
  std::unique_ptr<Scanner> scanner;
  ast::Unit* unit = null;
};

static ParsedUnit parse(SourceManager* sources, const std::string& text) {
  static int next_source_id = 0;
  ParsedUnit result;
  result.symbols.reset(new SymbolCanonicalizer());
  std::string path = "///<format-unit-" +
      std::to_string(next_source_id++) + ">";
  result.source = sources->load_from_memory(
      path,
      reinterpret_cast<const uint8*>(text.data()),
      text.size());
  NullDiagnostics diagnostics(sources);
  result.scanner.reset(
      new Scanner(result.source, result.symbols.get(), &diagnostics));
  Parser parser(result.source, result.scanner.get(), &diagnostics);
  result.unit = parser.parse_unit();
  ASSERT(!diagnostics.encountered_error());
  return result;
}

static std::string format(SourceManager* sources,
                          const std::string& input,
                          int preferred_extent = 100) {
  ParsedUnit parsed = parse(sources, input);
  FormatStyle style;
  style.preferred_extent = preferred_extent;
  style.indentation_pressure_divisor = 0;
  std::string output;
  ASSERT(format_unit(parsed.unit,
                     parsed.source,
                     parsed.scanner->comments(),
                     &output,
                     style));

  ParsedUnit reparsed = parse(sources, output);
  ASSERT(ast_equivalent(parsed.unit, reparsed.unit));
  std::string second;
  ASSERT(format_unit(reparsed.unit,
                     reparsed.source,
                     reparsed.scanner->comments(),
                     &second,
                     style));
  ASSERT(second == output);
  return output;
}

static void test_format_unit(SourceManager* sources) {
  const char* input =
      "import  ..foo.bar  as baz\n"
      "import expect show *\n"
      "export alpha beta\n"
      "abstract class Device extends Base with Mix implements Interface:\n"
      "    static VALUE /int ::= 1\n"
      "    configure --organization/string --application/string value/int -> bool:\n"
      "      if value: return true\n"
      "      else: return false\n"
      "main: return 0\n";
  const char* expected =
      "import ..foo.bar as baz\n"
      "import expect show *\n"
      "export alpha beta\n"
      "\n"
      "abstract class Device extends Base with Mix implements Interface:\n"
      "  static VALUE/int ::= 1\n"
      "\n"
      "  configure --organization/string --application/string value/int -> bool:\n"
      "    if value:\n"
      "      return true\n"
      "    else:\n"
      "      return false\n"
      "\n"
      "main:\n"
      "  return 0\n";
  ASSERT(format(sources, input) == expected);
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);
  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::test_format_unit(&sources);
  return 0;
}

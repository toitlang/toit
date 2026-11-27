// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <memory>
#include <string>

#include "../../src/compiler/ast_equivalence.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_expression.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-support.h"

namespace toit {
namespace compiler {

struct ParsedExpression {
  std::unique_ptr<SymbolCanonicalizer> symbols;
  Source* source = null;
  ast::Expression* expression = null;
};

static ParsedExpression parse_expression(SourceManager* sources,
                                         const std::string& text) {
  static int next_source_id = 0;
  ParsedExpression result;
  result.symbols.reset(new SymbolCanonicalizer());
  std::string indented_text;
  for (char c : text) {
    indented_text.push_back(c);
    if (c == '\n') indented_text += "  ";
  }
  std::string program = "sample:\n  return " + indented_text + "\n";
  std::string path = "///<format-expression-" +
      std::to_string(next_source_id++) + ">";
  result.source = sources->load_from_memory(
      path,
      reinterpret_cast<const uint8*>(program.data()),
      program.size());
  NullDiagnostics diagnostics(sources);
  Scanner scanner(result.source, result.symbols.get(), &diagnostics);
  Parser parser(result.source, &scanner, &diagnostics);
  ast::Unit* unit = parser.parse_unit();
  if (diagnostics.encountered_error()) {
    fprintf(stderr, "Failed to parse expression fixture:\n%s", program.c_str());
    exit(1);
  }
  ASSERT(unit->declarations().length() == 1);
  ast::Method* method = unit->declarations()[0]->as_Method();
  ASSERT(method != null && method->body() != null);
  ASSERT(method->body()->expressions().length() == 1);
  ast::Return* return_expression =
      method->body()->expressions()[0]->as_Return();
  ASSERT(return_expression != null);
  result.expression = return_expression->value();
  ASSERT(result.expression != null);
  return result;
}

static std::string format(SourceManager* sources,
                          const std::string& input,
                          int preferred_extent = 100,
                          bool parenthesize_mixed_bitwise = true) {
  ParsedExpression parsed = parse_expression(sources, input);
  FormatStyle style;
  style.preferred_extent = preferred_extent;
  style.indentation_pressure_divisor = 0;
  FormatExpressionOptions options;
  options.parenthesize_mixed_bitwise = parenthesize_mixed_bitwise;
  FormatOutput output_lines;
  ASSERT(format_expression(
      parsed.expression, parsed.source, 0, &output_lines, style, options));
  std::string output = output_lines.render(0);

  ParsedExpression reparsed = parse_expression(sources, output);
  if (!ast_nodes_equivalent(parsed.expression, reparsed.expression)) {
    fprintf(stderr,
            "Expression changed AST:\ninput:  %s\noutput: %s\n",
            input.c_str(),
            output.c_str());
    exit(1);
  }

  FormatOutput second_output;
  ASSERT(format_expression(
      reparsed.expression,
      reparsed.source,
      0,
      &second_output,
      style,
      options));
  ASSERT(second_output.render(0) == output);
  return output;
}

static void test_format_expression(SourceManager* sources) {
  ASSERT(format(sources, "(a + b) * c") == "(a + b) * c");
  ASSERT(format(sources, "((z))") == "z");
  ASSERT(format(sources, "foo and (bar or gee)") ==
      "foo and (bar or gee)");
  ASSERT(format(sources, "not (foo or bar)") == "not (foo or bar)");

  ASSERT(format(sources, "byte >> 4 & 0xf") ==
      "(byte >> 4) & 0xf");
  ASSERT(format(sources, "byte >> 4 & 0xf", 100, false) ==
      "byte >> 4 & 0xf");

  ASSERT(format(sources, "Foo.bar") == "Foo.bar");
  ASSERT(format(sources, "(Foo).bar") == "(Foo).bar");
  ASSERT(format(sources, "values[1]") == "values[1]");
  ASSERT(format(sources, "values[1..4]") == "values[1..4]");

  ASSERT(format(sources, "alpha-long + beta-long + gamma-long", 15) ==
      "alpha-long\n    + beta-long\n    + gamma-long");
  ASSERT(format(sources, "foo or bar or gee", 8) ==
      "foo or\n    bar or\n    gee");
  ASSERT(format(sources, "condition ? yes : no", 8) ==
      "condition\n    ? yes\n    : no");

  ASSERT(format(sources, "print  \"hello\"") == "print \"hello\"");
  ASSERT(format(
      sources,
      "consume arg01 arg02 arg03 arg04 arg05 arg06 arg07 arg08 arg09 arg10",
      65) ==
      "consume arg01 arg02 arg03 arg04 arg05 arg06 arg07 arg08 arg09 arg10");
  ASSERT(format(
      sources,
      "http-client.post-request encoded --host=server-host --port=server-port",
      38) ==
      "http-client.post-request encoded\n"
      "    --host=server-host\n"
      "    --port=server-port");
  ASSERT(format(
      sources,
      "send first-moderately-long second-moderately-long third-moderately-long",
      43) ==
      "send first-moderately-long \\\n"
      "    second-moderately-long third-moderately-long");
  ASSERT(format(sources, "consume (build x y)") == "consume (build x y)");
  ASSERT(format(sources, "(build x).field") == "(build x).field");
  ASSERT(format(sources, "1 + (compute x)") == "1 + (compute x)");
  ASSERT(format(sources, "configure --no-cache") ==
      "configure --no-cache");

  ASSERT(format(sources, "[]") == "[]");
  ASSERT(format(sources, "{}") == "{}");
  ASSERT(format(sources, "{:}") == "{:}");
  ASSERT(format(sources, "#[1,2,  3]") == "#[1, 2, 3]");
  ASSERT(format(sources, "{one:1,two: 2}") == "{one: 1, two: 2}");
  ASSERT(format(
      sources,
      "[aaaaaaaaaa, bbbbbbbbbb, cccccccccc, dddddddddd]",
      25) ==
      "[\n"
      "  aaaaaaaaaa, bbbbbbbbbb,\n"
      "  cccccccccc, dddddddddd,\n"
      "]");
  ASSERT(format(
      sources,
      "{first-long: one-long, second-long: two-long}",
      24) ==
      "{\n"
      "  first-long: one-long,\n"
      "  second-long: two-long,\n"
      "}");
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);

  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::test_format_expression(&sources);
  return 0;
}

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include <cstring>
#include <memory>

#include "../../src/compiler/ast.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_method.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-source.h"

namespace toit {
namespace compiler {

struct ParsedMethod {
  std::unique_ptr<FormatTestSource> source;
  std::unique_ptr<SymbolCanonicalizer> symbols;
  ast::Method* method;
};

static ParsedMethod parse_header(const std::string& header,
                                 SourceManager* sources) {
  if (header.empty() || header.back() != ':') exit(1);
  ParsedMethod result;
  result.source.reset(new FormatTestSource(header + "\n  null\n"));
  result.symbols.reset(new SymbolCanonicalizer());
  NullDiagnostics diagnostics(sources);
  Scanner scanner(result.source.get(), result.symbols.get(), &diagnostics);
  Parser parser(result.source.get(), &scanner, &diagnostics);
  ast::Unit* unit = parser.parse_unit();
  if (diagnostics.encountered_error() || unit->declarations().length() != 1) {
    exit(1);
  }
  result.method = unit->declarations()[0]->as_Method();
  if (result.method == null) exit(1);
  return result;
}

static bool same_symbol(Symbol left, Symbol right) {
  return std::strcmp(left.c_str(), right.c_str()) == 0;
}

static bool equivalent_header_expression(ast::Expression* left,
                                         ast::Expression* right) {
  if (left == null || right == null) return left == right;
  if (left->is_Identifier() && right->is_Identifier()) {
    return same_symbol(left->as_Identifier()->data(),
                       right->as_Identifier()->data());
  }
  if (left->is_Dot() && right->is_Dot()) {
    return equivalent_header_expression(left->as_Dot()->receiver(),
                                        right->as_Dot()->receiver())
        && equivalent_header_expression(left->as_Dot()->name(),
                                        right->as_Dot()->name());
  }
  if (left->is_Nullable() && right->is_Nullable()) {
    return equivalent_header_expression(left->as_Nullable()->type(),
                                        right->as_Nullable()->type());
  }
  if (left->is_LiteralInteger() && right->is_LiteralInteger()) {
    return same_symbol(left->as_LiteralInteger()->data(),
                       right->as_LiteralInteger()->data());
  }
  return false;
}

static bool equivalent_parameter(ast::Parameter* left,
                                 ast::Parameter* right) {
  return left->is_named() == right->is_named()
      && left->is_field_storing() == right->is_field_storing()
      && left->is_block() == right->is_block()
      && equivalent_header_expression(left->name(), right->name())
      && equivalent_header_expression(left->type(), right->type())
      && equivalent_header_expression(left->default_value(),
                                      right->default_value());
}

static bool equivalent_header(ast::Method* left, ast::Method* right) {
  if (left->is_setter() != right->is_setter() ||
      left->is_static() != right->is_static() ||
      left->is_abstract() != right->is_abstract() ||
      !equivalent_header_expression(left->name_or_dot(),
                                    right->name_or_dot()) ||
      !equivalent_header_expression(left->return_type(),
                                    right->return_type()) ||
      left->parameters().length() != right->parameters().length()) {
    return false;
  }
  for (int i = 0; i < left->parameters().length(); i++) {
    if (!equivalent_parameter(left->parameters()[i], right->parameters()[i])) {
      return false;
    }
  }
  return true;
}

static void expect(const char* expected, const std::string& actual) {
  if (actual == expected) return;
  fprintf(stderr, "Expected:\n---\n%s\n---\nActual:\n---\n%s\n---\n", expected,
          actual.c_str());
  exit(1);
}

static std::string render_header(ast::Method* method, Source* source,
                                 int preferred_width) {
  LayoutBuilder layouts;
  LogicalOperatorBindings bindings;
  SyntaxProtection syntax;
  LoweredMethodHeader lowered =
      lower_method_header(method, source, &layouts, &bindings, &syntax);

  // Method lowering feeds the same selection, whitespace-repair, freezing,
  // and syntax-insertion pipeline as expressions.
  SelectedPlan selected = select_method_header(lowered, preferred_width);
  WhitespaceEdits edits = FormatRepairs::propose(bindings, selected);
  if (!selected.apply(edits)) exit(1);
  FinalPlan final = std::move(selected).freeze();
  return render_plan(final, syntax.resolve(final));
}

static void test_parsed_method_headers(Source* source,
                                       ast::Unit* unit,
                                       SourceManager* sources) {
  ASSERT(unit->declarations().length() == 8);
  ast::Method* flat = unit->declarations()[0]->as_Method();
  ast::Method* source_split = unit->declarations()[1]->as_Method();
  ast::Method* plain = unit->declarations()[2]->as_Method();
  ast::Method* shapes = unit->declarations()[3]->as_Method();
  ast::Class* holder = unit->declarations()[4]->as_Class();
  ASSERT(holder != null && holder->members().length() == 2);
  ast::Method* declaration = holder->members()[0]->as_Method();
  ast::Method* index = holder->members()[1]->as_Method();
  ast::Class* fields = unit->declarations()[5]->as_Class();
  ASSERT(fields != null && fields->members().length() == 3);
  ast::Method* constructor = fields->members()[2]->as_Method();
  ast::Method* operator_name = unit->declarations()[6]->as_Method();

  expect("flat first second -> int:", render_header(flat, source, 100));
  expect("flat\n    first\n    second -> int:",
         render_header(flat, source, 20));

  // Input newlines and the input position of `->` do not become preferences.
  // Both ASTs receive the same canonical token order for the selected shape.
  expect("source-split first second -> int:",
         render_header(source_split, source, 100));
  expect("source-split\n    first\n    second -> int:",
         render_header(source_split, source, 24));

  // Without a return type there is no structural exception. Generic selection
  // keeps source token order and merely breaks the parameter gaps.
  expect("plain\n    first\n    second:", render_header(plain, source, 12));

  // Named, block, typed, and defaulted parameters are ordinary parameter
  // components. Their spelling does not create separate layout policies.
  expect("shapes value/string? --named=1 [block] -> int?:",
         render_header(shapes, source, 100));
  expect("shapes\n"
         "    value/string?\n"
         "    --named=1\n"
         "    [block] -> int?:",
         render_header(shapes, source, 30));

  expect("static declaration value -> int:",
         render_header(declaration, source, 100));
  expect("static declaration\n    value -> int:",
         render_header(declaration, source, 24));

  expect("operator [] index -> int:",
         render_header(index, source, 100));
  expect("constructor this.value .other:",
         render_header(constructor, source, 100));
  expect("operator-name -> int:",
         render_header(operator_name, source, 100));

  // Exact strings are not enough: reparse both flat and broken headers,
  // compare their semantic header trees, and format them a second time to
  // verify idempotence.
  ast::Method* methods[] = {
      flat, flat, source_split, source_split, plain,
      shapes, declaration, index, constructor, operator_name,
  };
  int widths[] = {100, 20, 100, 24, 12, 30, 24, 100, 100, 100};
  for (int i = 0; i < 10; i++) {
    std::string rendered = render_header(methods[i], source, widths[i]);
    ParsedMethod reparsed = parse_header(rendered, sources);
    if (!equivalent_header(methods[i], reparsed.method)) exit(1);
    expect(rendered.c_str(),
           render_header(reparsed.method, reparsed.source.get(), widths[i]));
  }
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);

  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::NullDiagnostics diagnostics(&sources);
  toit::compiler::SourceManager::LoadResult loaded =
      sources.load_file(argv[1], toit::compiler::Package::invalid());
  ASSERT(loaded.status == toit::compiler::SourceManager::LoadResult::OK);

  toit::compiler::SymbolCanonicalizer symbols;
  toit::compiler::Scanner scanner(loaded.source, &symbols, &diagnostics);
  toit::compiler::Parser parser(loaded.source, &scanner, &diagnostics);
  toit::compiler::ast::Unit* unit = parser.parse_unit();
  ASSERT(!diagnostics.encountered_error());

  toit::compiler::test_parsed_method_headers(loaded.source, unit, &sources);
  return 0;
}

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include <cstring>
#include <memory>
#include <string>

#include "../../src/compiler/ast.h"
#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_body.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-source.h"

namespace toit {
namespace compiler {

struct ParsedBody {
  std::unique_ptr<FormatTestSource> source;
  std::unique_ptr<SymbolCanonicalizer> symbols;
  std::unique_ptr<FormatTrivia> trivia;
  ast::Sequence* body;
  int from;
  int to;
};

static ParsedBody parse_body(const std::string& body, SourceManager* sources) {
  std::string program = "sample x:\n  ";
  for (char c : body) {
    if (c == '\n') {
      program += "\n  ";
    } else {
      program += c;
    }
  }
  program += '\n';

  ParsedBody result;
  result.source.reset(new FormatTestSource(program));
  result.symbols.reset(new SymbolCanonicalizer());
  NullDiagnostics diagnostics(sources);
  Scanner scanner(result.source.get(), result.symbols.get(), &diagnostics);
  Parser parser(result.source.get(), &scanner, &diagnostics);
  ast::Unit* unit = parser.parse_unit();
  if (diagnostics.encountered_error() || unit->declarations().length() != 1) {
    fprintf(stderr, "Failed to parse rendered body\n");
    exit(1);
  }
  ast::Method* method = unit->declarations()[0]->as_Method();
  if (method == null || method->body() == null) exit(1);
  result.trivia.reset(
      new FormatTrivia(result.source.get(), scanner.comments()));
  result.body = method->body();
  result.from = static_cast<int>(std::strlen("sample x:"));
  result.to = result.source->size();
  return result;
}

static ast::Expression* peel_parentheses(ast::Expression* expression) {
  while (expression->is_Parenthesis()) {
    expression = expression->as_Parenthesis()->expression();
  }
  return expression;
}

static bool same_symbol(Symbol left, Symbol right) {
  return std::strcmp(left.c_str(), right.c_str()) == 0;
}

static bool equivalent(ast::Expression* left, ast::Expression* right) {
  if (left == null || right == null) return left == right;
  left = peel_parentheses(left);
  right = peel_parentheses(right);
  if (left->is_Identifier() && right->is_Identifier()) {
    return same_symbol(left->as_Identifier()->data(),
                       right->as_Identifier()->data());
  }
  if (left->is_LiteralInteger() && right->is_LiteralInteger()) {
    return same_symbol(left->as_LiteralInteger()->data(),
                       right->as_LiteralInteger()->data());
  }
  if (left->is_Unary() && right->is_Unary()) {
    ast::Unary* left_unary = left->as_Unary();
    ast::Unary* right_unary = right->as_Unary();
    return left_unary->kind() == right_unary->kind() &&
           left_unary->prefix() == right_unary->prefix() &&
           equivalent(left_unary->expression(), right_unary->expression());
  }
  if (left->is_Binary() && right->is_Binary()) {
    ast::Binary* left_binary = left->as_Binary();
    ast::Binary* right_binary = right->as_Binary();
    return left_binary->kind() == right_binary->kind() &&
           equivalent(left_binary->left(), right_binary->left()) &&
           equivalent(left_binary->right(), right_binary->right());
  }
  if (left->is_Call() && right->is_Call()) {
    ast::Call* left_call = left->as_Call();
    ast::Call* right_call = right->as_Call();
    if (!equivalent(left_call->target(), right_call->target()) ||
        left_call->arguments().length() != right_call->arguments().length()) {
      return false;
    }
    for (int i = 0; i < left_call->arguments().length(); i++) {
      if (!equivalent(left_call->arguments()[i], right_call->arguments()[i]))
        return false;
    }
    return true;
  }
  if (left->is_Return() && right->is_Return()) {
    return equivalent(left->as_Return()->value(), right->as_Return()->value());
  }
  if (left->is_If() && right->is_If()) {
    ast::If* left_if = left->as_If();
    ast::If* right_if = right->as_If();
    return equivalent(left_if->expression(), right_if->expression()) &&
           equivalent(left_if->yes(), right_if->yes()) &&
           equivalent(left_if->no(), right_if->no());
  }
  if (left->is_Sequence() && right->is_Sequence()) {
    List<ast::Expression*> left_expressions =
        left->as_Sequence()->expressions();
    List<ast::Expression*> right_expressions =
        right->as_Sequence()->expressions();
    if (left_expressions.length() != right_expressions.length()) return false;
    for (int i = 0; i < left_expressions.length(); i++) {
      if (!equivalent(left_expressions[i], right_expressions[i])) return false;
    }
    return true;
  }
  return false;
}

static void expect(const char* expected, const std::string& actual) {
  if (actual == expected) return;
  fprintf(stderr, "Expected:\n---\n%s\n---\nActual:\n---\n%s\n---\n", expected,
          actual.c_str());
  exit(1);
}

static std::string render_body(ast::Sequence* body,
                               Source* source,
                               int from,
                               int to,
                               int preferred_width,
                               const FormatTrivia* trivia) {
  LayoutBuilder layouts;
  LogicalOperatorBindings bindings;
  SyntaxProtection syntax;
  TriviaLowering trivia_lowering(trivia, &layouts);
  Layout* layout = lower_body(body, source, from, to, &layouts, &bindings,
                              &syntax, &trivia_lowering);
  SelectedPlan selected = select_layout(layout, preferred_width);
  WhitespaceEdits edits = FormatRepairs::propose(bindings, selected);
  if (!selected.apply(edits)) {
    fprintf(stderr, "Body repairs conflicted\n");
    exit(1);
  }
  FinalPlan final = std::move(selected).freeze();
  return render_plan(final, syntax.resolve(final));
}

static void test_body(Source* source,
                      ast::Unit* unit,
                      SourceManager* sources,
                      const FormatTrivia* trivia) {
  ASSERT(unit->declarations().length() == 2);
  ast::Method* sample = unit->declarations()[0]->as_Method();
  ast::Method* main = unit->declarations()[1]->as_Method();
  ASSERT(sample != null && sample->body() != null && main != null);
  int from = source->offset_in_source(sample->name_or_dot()->full_range().to());
  const uint8* text = source->text();
  while (from < source->size() && text[from] != ':') from++;
  ASSERT(from < source->size());
  from++;
  int to = source->offset_in_source(main->full_range().from());

  const char* expected =
      "x  +   1  // Keep   every byte.\n"
      "if not x:\n"
      "  // Do nothing.\n"
      "if  x:  // Keep   header bytes.\n"
      "  return 1\n"
      "// This belongs to the outer body.\n"
      "if x:\n"
      "  x\n"
      "  /* Avoid joining\n"
      "     the two lines. */\n"
      "  return 499\n"
      "x/*attached*/\n"
      "return   x  // Keep   return bytes.\n"
      "/* Last body comment. */";
  std::string rendered =
      render_body(sample->body(), source, from, to, 20, trivia);
  expect(expected, rendered);

  ParsedBody reparsed = parse_body(rendered, sources);
  if (!equivalent(sample->body(), reparsed.body)) {
    fprintf(stderr, "Rendered body changed the AST\n");
    exit(1);
  }
  expect(rendered.c_str(),
         render_body(reparsed.body, reparsed.source.get(), reparsed.from,
                     reparsed.to, 20, reparsed.trivia.get()));
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
  toit::compiler::FormatTrivia trivia(loaded.source, scanner.comments());
  toit::compiler::test_body(loaded.source, unit, &sources, &trivia);
  return 0;
}

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
#include "../../src/compiler/format_expression.h"
#include "../../src/compiler/parser.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-source.h"

namespace toit {
namespace compiler {

struct ParsedExpression {
  std::unique_ptr<FormatTestSource> source;
  std::unique_ptr<SymbolCanonicalizer> symbols;
  ast::Expression* expression;
};

static ParsedExpression parse_expression(const std::string& expression,
                                         SourceManager* sources) {
  std::string program = "sample:\n  ";
  for (char c : expression) {
    program += c;
    if (c == '\n') program += "  ";
  }
  program += '\n';

  ParsedExpression result;
  result.source.reset(new FormatTestSource(program));
  result.symbols.reset(new SymbolCanonicalizer());
  NullDiagnostics diagnostics(sources);
  Scanner scanner(result.source.get(), result.symbols.get(), &diagnostics);
  Parser parser(result.source.get(), &scanner, &diagnostics);
  ast::Unit* unit = parser.parse_unit();
  if (diagnostics.encountered_error()
      || unit->declarations().length() != 1) exit(1);
  ast::Method* method = unit->declarations()[0]->as_Method();
  if (method == null || method->body()->expressions().length() != 1) exit(1);
  result.expression = method->body()->expressions()[0];
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

// This comparator deliberately covers exactly the expression kinds supported
// by format_expression.cc. Adding a lowering rule without extending this
// safety check makes the reparse test fail instead of silently weakening it.
static bool equivalent_expression(ast::Expression* left,
                                  ast::Expression* right) {
  left = peel_parentheses(left);
  right = peel_parentheses(right);
  if (left->is_Identifier() && right->is_Identifier()) {
    return same_symbol(left->as_Identifier()->data(),
                       right->as_Identifier()->data());
  }
  if (left->is_LiteralInteger() && right->is_LiteralInteger()) {
    return left->as_LiteralInteger()->is_negated()
               == right->as_LiteralInteger()->is_negated()
        && same_symbol(left->as_LiteralInteger()->data(),
                       right->as_LiteralInteger()->data());
  }
  if (left->is_LiteralNull() && right->is_LiteralNull()) return true;
  if (left->is_LiteralUndefined() && right->is_LiteralUndefined()) return true;
  if (left->is_LiteralBoolean() && right->is_LiteralBoolean()) {
    return left->as_LiteralBoolean()->value()
        == right->as_LiteralBoolean()->value();
  }
  if (left->is_LiteralCharacter() && right->is_LiteralCharacter()) {
    return same_symbol(left->as_LiteralCharacter()->data(),
                       right->as_LiteralCharacter()->data());
  }
  if (left->is_LiteralString() && right->is_LiteralString()) {
    return left->as_LiteralString()->is_multiline()
               == right->as_LiteralString()->is_multiline()
        && same_symbol(left->as_LiteralString()->data(),
                       right->as_LiteralString()->data());
  }
  if (left->is_LiteralFloat() && right->is_LiteralFloat()) {
    return left->as_LiteralFloat()->is_negated()
               == right->as_LiteralFloat()->is_negated()
        && same_symbol(left->as_LiteralFloat()->data(),
                       right->as_LiteralFloat()->data());
  }
  if (left->is_Unary() && right->is_Unary()) {
    ast::Unary* left_unary = left->as_Unary();
    ast::Unary* right_unary = right->as_Unary();
    return left_unary->kind() == right_unary->kind()
        && left_unary->prefix() == right_unary->prefix()
        && equivalent_expression(left_unary->expression(),
                                 right_unary->expression());
  }
  if (left->is_Binary() && right->is_Binary()) {
    ast::Binary* left_binary = left->as_Binary();
    ast::Binary* right_binary = right->as_Binary();
    return left_binary->kind() == right_binary->kind()
        && equivalent_expression(left_binary->left(), right_binary->left())
        && equivalent_expression(left_binary->right(), right_binary->right());
  }
  if (left->is_Call() && right->is_Call()) {
    ast::Call* left_call = left->as_Call();
    ast::Call* right_call = right->as_Call();
    if (left_call->is_call_primitive() != right_call->is_call_primitive()
        || !equivalent_expression(left_call->target(), right_call->target())) {
      return false;
    }
    if (left_call->arguments().length() != right_call->arguments().length()) {
      return false;
    }
    for (int i = 0; i < left_call->arguments().length(); i++) {
      if (!equivalent_expression(left_call->arguments()[i],
                                 right_call->arguments()[i])) return false;
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

static std::string render_expression(ast::Expression* expression,
                                     Source* source, int preferred_width,
                                     bool apply_repairs = true) {
  LayoutBuilder layouts;
  LogicalOperatorBindings bindings;
  SyntaxProtection syntax;
  LoweredExpression lowered =
      lower_expression(expression, source, &layouts, &bindings, &syntax);
  SelectedPlan selected = select_layout(lowered.layout, preferred_width);
  if (apply_repairs) {
    WhitespaceEdits edits = FormatRepairs::propose(bindings, selected);
    if (!selected.apply(edits)) exit(1);
  }
  FinalPlan final = std::move(selected).freeze();
  return render_plan(final, syntax.resolve(final));
}

static void test_conflicting_repairs_are_rejected_atomically() {
  LayoutBuilder builder;
  LayoutGap gap = builder.gap();
  Layout* layout = builder.group(builder.concat({
      builder.text("left"),
      builder.line(gap),
      builder.text("right"),
  }));
  SelectedPlan selected = select_layout(layout, 100);

  WhitespaceEdits edits;
  if (edits.request(gap, GapState::FLAT, "first-rule") !=
      WhitespaceEdits::ADDED) exit(1);
  if (edits.request(gap, GapState::FLAT, "compatible-rule") !=
      WhitespaceEdits::ALREADY_REQUESTED) exit(1);
  if (edits.request(gap, GapState::NEWLINE, "conflicting-rule") !=
      WhitespaceEdits::CONFLICT) exit(1);
  if (!edits.has_conflict() || edits.conflicts().size() != 1) exit(1);
  if (selected.apply(edits)) exit(1);

  // A conflict is detected before the plan is touched; the generic choice is
  // still available for diagnostics or safe fallback behavior.
  expect("left right", render_plan(std::move(selected).freeze()));
}

static void test_parsed_expressions(Source* source,
                                    ast::Unit* unit,
                                    SourceManager* sources) {
  ASSERT(unit->declarations().length() == 4);
  ast::Method* sample = unit->declarations()[2]->as_Method();
  ASSERT(sample != null);
  List<ast::Expression*> expressions = sample->body()->expressions();
  ASSERT(expressions.length() == 5);

  // Source parentheses disappear from the logical layout. They return only
  // when the selected topology needs them to keep the nested call together.
  expect("outer (inner 1)", render_expression(expressions[0], source, 20));
  expect("outer\n    inner 1", render_expression(expressions[0], source, 11));

  // Precedence protection is independent of line selection. The source tree
  // is `(a + b) * c`; after peeling source parens, the syntax pass reconstructs
  // the one pair required to preserve that tree.
  // Its logical width is nine; the reconstructed parens are deliberately not
  // counted even though they make the physical result eleven columns wide.
  expect("(a + b) * c", render_expression(expressions[1], source, 9));

  // Breaking the lower-precedence `or` first keeps the tighter `and` group
  // together and places the continuation at a fixed four-space indent. The
  // generic plan remains regular and correct; the post-selection matcher owns
  // the complete aesthetic adjustment.
  expect("foo\n    or bar\n        and gee",
         render_expression(expressions[2], source, 16, false));
  expect("foo or\n    bar and gee",
         render_expression(expressions[2], source, 16));

  // Canonicalization removes redundant source parens, not meaningful tree
  // structure. The lower-precedence `or` must be protected when it is the
  // left operand of `and`.
  expect("(foo or bar) and gee",
         render_expression(expressions[3], source, 100));

  // The input split after `or` is not retained as a preference. With room for
  // the canonical flat form, selection joins it again.
  expect("alpha or beta", render_expression(expressions[4], source, 100));

  // Reparse representative flat and broken results, compare their trees, and
  // format the reparsed trees again. This catches both semantic changes and
  // non-idempotent layout decisions without counting source parens as nodes.
  const int widths[] = {20, 11, 9, 16, 100, 100};
  const int indices[] = {0, 0, 1, 2, 3, 4};
  for (int i = 0; i < 6; i++) {
    ast::Expression* original = expressions[indices[i]];
    std::string rendered = render_expression(original, source, widths[i]);
    ParsedExpression reparsed = parse_expression(rendered, sources);
    if (!equivalent_expression(original, reparsed.expression)) exit(1);
    expect(rendered.c_str(),
           render_expression(reparsed.expression,
                             reparsed.source.get(),
                             widths[i]));
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

  toit::compiler::test_conflicting_repairs_are_rejected_atomically();
  toit::compiler::test_parsed_expressions(loaded.source, unit, &sources);
  return 0;
}

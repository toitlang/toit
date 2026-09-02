// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include "../../src/compiler/format_layout.h"
#include "../../src/compiler/format_syntax.h"
#include "../../src/top.h"

namespace toit {
namespace compiler {

static void expect(const char* expected, const std::string& actual) {
  if (actual == expected) return;
  fprintf(stderr, "Expected:\n---\n%s\n---\nActual:\n---\n%s\n---\n", expected,
          actual.c_str());
  exit(1);
}

static void test_precedence_protection_is_unconditional() {
  LayoutBuilder builder;
  LayoutMarker start = builder.marker();
  LayoutMarker end = builder.marker();
  Layout* multiplication = builder.concat({
      builder.mark(start),
      builder.text("a + b"),
      builder.mark(end),
      builder.text(" * c"),
  });

  SyntaxProtection syntax;
  syntax.require_parentheses({start, end});
  FinalPlan selected = std::move(select_layout(multiplication, 100)).freeze();
  PlanInsertions insertions = syntax.resolve(selected);

  expect("(a + b) * c", render_plan(selected, insertions));
}

static void test_nested_call_uses_the_selected_line_as_delimiter() {
  LayoutBuilder builder;
  LayoutMarker target_end = builder.marker();
  LayoutMarker argument_start = builder.marker();
  LayoutMarker argument_end = builder.marker();
  Layout* call = builder.group(builder.concat({
      builder.text("foo"),
      builder.mark(target_end),
      builder.indent(4, builder.concat({
                            builder.line(),
                            builder.mark(argument_start),
                            builder.text("bar 1"),
                            builder.mark(argument_end),
                        })),
  }));

  SyntaxProtection syntax;
  syntax.require_parentheses_unless_break_between(
      {argument_start, argument_end}, target_end);

  FinalPlan flat = std::move(select_layout(call, 20)).freeze();
  expect("foo (bar 1)", render_plan(flat, syntax.resolve(flat)));

  FinalPlan broken = std::move(select_layout(call, 6)).freeze();
  expect("foo\n    bar 1", render_plan(broken, syntax.resolve(broken)));
}

static void test_protection_does_not_turn_a_preference_into_a_limit() {
  LayoutBuilder builder;
  LayoutMarker start = builder.marker();
  LayoutMarker end = builder.marker();
  Layout* expression = builder.concat({
      builder.mark(start),
      builder.text("seven77"),
      builder.mark(end),
  });

  SyntaxProtection syntax;
  syntax.require_parentheses({start, end});
  FinalPlan selected = std::move(select_layout(expression, 7)).freeze();

  // The logical expression fits exactly. Required punctuation may make the
  // physical line wider because preferred_width is intentionally not a hard
  // limit and selection has already finished.
  expect("(seven77)", render_plan(selected, syntax.resolve(selected)));
}

} // namespace compiler
} // namespace toit

int main() {
  toit::throwing_new_allowed = true;
  toit::compiler::test_precedence_protection_is_unconditional();
  toit::compiler::test_nested_call_uses_the_selected_line_as_delimiter();
  toit::compiler::test_protection_does_not_turn_a_preference_into_a_limit();
  return 0;
}

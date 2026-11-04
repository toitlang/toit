// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include "../../src/compiler/format_layout.h"
#include "../../src/top.h"

namespace toit {
namespace compiler {

static void expect(const char* expected, const std::string& actual) {
  if (actual == expected) return;
  fprintf(stderr, "Expected:\n---\n%s\n---\nActual:\n---\n%s\n---\n", expected,
          actual.c_str());
  exit(1);
}

static std::string select_and_render(Layout* layout, int preferred_width) {
  return render_plan(
      std::move(select_layout(layout, preferred_width)).freeze());
}

static void test_group_selects_flat_or_broken() {
  LayoutBuilder builder;
  Layout* layout = builder.group(builder.concat({
      builder.text("send"),
      builder.indent(4, builder.concat({
                            builder.line(),
                            builder.text("argument"),
                        })),
  }));

  expect("send argument", select_and_render(layout, 20));
  expect("send\n    argument", select_and_render(layout, 10));
}

static void test_preferred_width_is_not_a_hard_limit() {
  LayoutBuilder builder;
  Layout* indivisible = builder.text("one-very-long-identifier");

  // There is no legal place to split this token. The formatter emits it
  // unchanged instead of inventing a hard-width failure mode.
  expect("one-very-long-identifier", select_and_render(indivisible, 5));
}

static void test_markers_follow_selected_lines() {
  LayoutBuilder builder;
  LayoutMarker outer_start = builder.marker();
  LayoutMarker inner_start = builder.marker();
  LayoutMarker inner_end = builder.marker();
  Layout* nested_call = builder.group(builder.concat({
      builder.mark(outer_start),
      builder.text("foo"),
      builder.indent(4, builder.concat({
                            builder.line(),
                            builder.mark(inner_start),
                            builder.text("bar 1"),
                            builder.mark(inner_end),
                        })),
  }));

  SelectedPlan flat = select_layout(nested_call, 20);
  ASSERT(!flat.has_break_between(outer_start, inner_start));
  ASSERT(flat.line_of(outer_start) == flat.line_of(inner_start));

  SelectedPlan broken = select_layout(nested_call, 6);
  ASSERT(broken.has_break_between(outer_start, inner_start));
  ASSERT(broken.line_of(outer_start) != broken.line_of(inner_start));
}

static void test_inserted_syntax_never_changes_a_break_decision() {
  LayoutBuilder builder;
  LayoutMarker start = builder.marker();
  LayoutMarker end = builder.marker();
  Layout* layout = builder.group(builder.concat({
      builder.text("abc "),
      builder.mark(start),
      builder.text("def"),
      builder.mark(end),
  }));

  FinalPlan selected = std::move(select_layout(layout, 7)).freeze();
  PlanInsertions insertions;
  insertions.insert_before(start, "(((");
  insertions.insert_before(end, ")))");

  // The physical result is wider than seven columns by design. Synthesized
  // protection is absent from the logical width used for line selection.
  expect("abc (((def)))", render_plan(selected, insertions));
}

static void test_hardline_preserves_structural_boundaries() {
  LayoutBuilder builder;
  Layout* statements = builder.concat({
      builder.text("first"),
      builder.hardline(),
      builder.text("second"),
  });

  expect("first\nsecond", select_and_render(statements, 100));
}

} // namespace compiler
} // namespace toit

int main() {
  toit::throwing_new_allowed = true;
  toit::compiler::test_group_selects_flat_or_broken();
  toit::compiler::test_preferred_width_is_not_a_hard_limit();
  toit::compiler::test_markers_follow_selected_lines();
  toit::compiler::test_inserted_syntax_never_changes_a_break_decision();
  toit::compiler::test_hardline_preserves_structural_boundaries();
  return 0;
}

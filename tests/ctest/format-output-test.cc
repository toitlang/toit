// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <string>

#include "../../src/compiler/format_output.h"
#include "../../src/top.h"
#include "format-test-support.h"

namespace toit {
namespace compiler {

static void test_soft_width_and_item_pressure() {
  FormatStyle style;
  ASSERT(is_flat_acceptable(110, 0, 9, 9, 0, style));
  ASSERT(!is_flat_acceptable(180, 0, 3, 3, 0, style));
}

static void test_indentation_pressure() {
  FormatStyle style;
  ASSERT(is_flat_acceptable(101, 0, 1, 1, 0, style));
  ASSERT(!is_flat_acceptable(101, 40, 1, 1, 0, style));

  style.indentation_pressure_divisor = 0;
  ASSERT(is_flat_acceptable(101, 40, 1, 1, 0, style));
}

static void test_rendering_and_break_preference() {
  FormatOutput output = FormatOutput::single_line("first \\");
  output.add_line(4, "second");
  ASSERT(output.render(2, true) == "  first \\\n      second\n");

  FormatStyle style;
  ASSERT(!is_flat_acceptable(107, 0, 1, 1, 0, style));
  ASSERT(is_flat_acceptable(107, 0, 1, 1, style.backslash_penalty * 3, style));
}

static void test_utf8_width() {
  ASSERT(utf8_code_point_width("plain") == 5);
  ASSERT(utf8_code_point_width("h\xc3\xa9j") == 3);
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);
  toit::compiler::test_soft_width_and_item_pressure();
  toit::compiler::test_indentation_pressure();
  toit::compiler::test_rendering_and_break_preference();
  toit::compiler::test_utf8_width();
  return 0;
}

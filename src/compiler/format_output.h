// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#include <stdint.h>

#include <string>
#include <vector>

namespace toit {
namespace compiler {

struct FormatStyle {
  int indentation_step = 2;
  int continuation_step = 4;

  // These values define a soft flat-layout preference, not an output limit.
  int preferred_extent = 100;
  int indentation_pressure_divisor = 4;
  int width_penalty = 1;
  int line_penalty = 20;
  int split_item_penalty = 5;
  int backslash_penalty = 10;

  int max_blank_lines = 2;
  int trailing_comment_gap = 2;
};

struct FormatOutputLine {
  int indentation = 0;
  std::string text;
};

// The selected, grammar-legal output of an AST printer. Speculative layouts
// are never stored here. Lines carry indentation relative to the AST node's
// enclosing indentation.
class FormatOutput {
 public:
  static FormatOutput single_line(const std::string& text);

  void append(const std::string& text);
  void add_line(int indentation, const std::string& text);

  const std::vector<FormatOutputLine>& lines() const { return lines_; }

  std::string render(int base_indentation, bool final_newline = false) const;

 private:
  std::vector<FormatOutputLine> lines_;
};

int utf8_code_point_width(const std::string& text);

// Returns whether a construct's flat spelling is acceptable. $broken_lines,
// $split_items, and $broken_penalty are deliberately rough estimates of the
// alternative's readability cost; no broken output is built or measured.
bool is_flat_acceptable(int estimated_width, int base_indentation,
                        int broken_lines, int split_items,
                        int broken_penalty = 0,
                        const FormatStyle& style = FormatStyle());

// Returns the preferred local extent after applying the slight pressure from
// the enclosing indentation. This is useful for greedy row packing after a
// construct has already decided to break.
int preferred_extent_at(int base_indentation,
                        const FormatStyle& style = FormatStyle());

} // namespace compiler
} // namespace toit

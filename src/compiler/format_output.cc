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

#include "format_output.h"

#include <algorithm>

#include "../top.h"

namespace toit {
namespace compiler {

static void check_single_line(const std::string& text) {
  ASSERT(text.find('\n') == std::string::npos);
  ASSERT(text.find('\r') == std::string::npos);
}

FormatOutput FormatOutput::single_line(const std::string& text) {
  check_single_line(text);
  FormatOutput result;
  result.add_line(0, text);
  return result;
}

void FormatOutput::append(const std::string& text) {
  check_single_line(text);
  ASSERT(!lines_.empty());
  lines_.back().text += text;
}

void FormatOutput::add_line(int indentation, const std::string& text) {
  ASSERT(indentation >= 0);
  check_single_line(text);
  FormatOutputLine line;
  line.indentation = indentation;
  line.text = text;
  lines_.push_back(line);
}

std::string FormatOutput::render(int base_indentation,
                                 bool final_newline) const {
  ASSERT(base_indentation >= 0);
  std::string result;
  for (int i = 0; i < static_cast<int>(lines_.size()); i++) {
    if (i > 0) result.push_back('\n');
    result.append(base_indentation + lines_[i].indentation, ' ');
    result += lines_[i].text;
  }
  if (final_newline) result.push_back('\n');
  return result;
}

int utf8_code_point_width(const std::string& text) {
  int result = 0;
  for (unsigned char c : text) {
    if ((c & 0xc0) != 0x80) result++;
  }
  return result;
}

int preferred_extent_at(int base_indentation, const FormatStyle& style) {
  ASSERT(base_indentation >= 0);
  ASSERT(style.preferred_extent >= 0);
  int pressure = style.indentation_pressure_divisor <= 0
      ? 0
      : base_indentation / style.indentation_pressure_divisor;
  return std::max(0, style.preferred_extent - pressure);
}

bool is_flat_acceptable(int estimated_width, int base_indentation,
                        int broken_lines, int split_items, int broken_penalty,
                        const FormatStyle& style) {
  ASSERT(estimated_width >= 0);
  ASSERT(base_indentation >= 0);
  ASSERT(broken_lines >= 0);
  ASSERT(split_items >= 0);
  ASSERT(broken_penalty >= 0);
  ASSERT(style.width_penalty >= 0);
  ASSERT(style.line_penalty >= 0);
  ASSERT(style.split_item_penalty >= 0);
  int overflow = estimated_width - preferred_extent_at(base_indentation, style);
  if (overflow <= 0) return true;
  int64_t flat_cost = static_cast<int64_t>(overflow) * overflow *
      style.width_penalty;
  int64_t break_cost = static_cast<int64_t>(broken_lines) *
          style.line_penalty +
      static_cast<int64_t>(split_items) * style.split_item_penalty +
      broken_penalty;
  return flat_cost <= break_cost;
}

} // namespace compiler
} // namespace toit

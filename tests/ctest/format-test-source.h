// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#pragma once

#include <string>

#include "../../src/compiler/sources.h"

namespace toit {
namespace compiler {

// An in-memory Source for semantic formatter tests. It lets tests reparse the
// exact rendered bytes without depending on temporary-file behavior across
// host platforms.
class FormatTestSource : public Source {
 public:
  explicit FormatTestSource(const std::string& text) : text_(text) {}

  const char* absolute_path() const override { return "///format-test.toit"; }
  Package package() const override { return Package::invalid(); }
  std::string error_path() const override { return absolute_path(); }
  const uint8* text() const override {
    return reinterpret_cast<const uint8*>(text_.data());
  }
  Range range(int from, int to) const override {
    return Range(Position::from_token(from), Position::from_token(to));
  }
  int size() const override { return static_cast<int>(text_.size()); }
  int offset_in_source(Position position) const override {
    int offset = position.token();
    return 0 <= offset && offset <= size() ? offset : -1;
  }
  bool is_lsp_marker_at(int offset) override {
    USE(offset);
    return false;
  }
  void text_range_without_marker(int from,
                                 int to,
                                 const uint8** text_from,
                                 const uint8** text_to) override {
    *text_from = text() + from;
    *text_to = text() + to;
  }

 private:
  std::string text_;
};

} // namespace compiler
} // namespace toit

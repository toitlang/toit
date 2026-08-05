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

#include <string>
#include <vector>

#include "format_layout.h"
#include "scanner.h"

namespace toit {
namespace compiler {

class Source;

// Immutable source facts collected before layout lowering. Trivia does not
// survive as a parallel rendering model: each formatting run consumes these
// entries into ordinary text and hard-line layouts.
class FormatTrivia {
 public:
  struct Comment {
    int from;
    int to;
    int line_start;
    int line_end;
    int original_column;
    bool is_line_comment;
    bool spans_lines;
    bool has_code_before;
    std::string text;
  };

  FormatTrivia(Source* source, List<Scanner::Comment> comments);

  Source* source() const { return source_; }
  const std::vector<Comment>& comments() const { return comments_; }

 private:
  Source* source_;
  std::vector<Comment> comments_;
};

// Per-rendering consumer for FormatTrivia. A comment is converted to a Layout
// exactly once, after which selection and rendering need no trivia-specific
// behavior.
class TriviaLowering {
 public:
  TriviaLowering(const FormatTrivia* trivia, LayoutBuilder* layouts);

  // A real `//` comment freezes the source line. For the current expression
  // and header slices the smallest safely replaceable unit may span several
  // source lines; `verbatim_region` preserves all non-indentation bytes in
  // that unit and shifts its lines by the unit's original base indentation.
  int first_line_comment(int from, int to, bool include_trailing_line) const;
  const FormatTrivia::Comment& comment(int id) const;
  int find_syntax(int from, int to, const char* syntax) const;
  Layout* verbatim_region(int from, int to);

  // Blindly concatenates consecutive, same-line block comments immediately
  // before or after a semantic component. Whitespace is canonicalized to no
  // gap when the comment is glued and one space otherwise.
  Layout* take_inline_prefix(Layout* core, int from, int to);
  Layout* take_inline_suffix(Layout* core, int from, int to);

  // Converts an own-line block comment to an exact, reindentable layout. The
  // caller supplies its structural hard-line boundaries because indentation
  // belongs to the containing statement/argument/element list.
  Layout* take_own_line_block(int id);

  bool all_comments_consumed() const;

 private:
  const FormatTrivia* trivia_;
  LayoutBuilder* layouts_;
  std::vector<bool> consumed_;

  bool only_horizontal_space(int from, int to) const;
  Layout* inline_comment(int id);
  Layout* exact_multiline_text(const FormatTrivia::Comment& comment,
                               int base_column);
};

} // namespace compiler
} // namespace toit

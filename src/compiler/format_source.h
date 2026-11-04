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

#include "scanner.h"
#include "sources.h"

namespace toit {
namespace compiler {

struct FormatLine {
  int from = 0;
  int content_to = 0;
  int to = 0;
  int indentation = 0;
  int trailing_line_comment = -1;

  bool is_frozen() const { return trailing_line_comment >= 0; }
};

struct FormatComment {
  int id = -1;
  int from = 0;
  int to = 0;
  int start_line = -1;
  int end_line = -1;
  int start_column = 0;
  bool is_block = false;
  bool is_toitdoc = false;
  bool spans_lines = false;
  bool follows_code = false;
  std::string text;
};

// Immutable physical source facts used while comments are attached to AST
// pieces. This class does not decide formatting or comment ownership.
class FormatSource {
 public:
  FormatSource(Source* source, List<Scanner::Comment> comments);

  Source* source() const { return source_; }
  const std::vector<FormatLine>& lines() const { return lines_; }
  const std::vector<FormatComment>& comments() const { return comments_; }

  int line_index_at(int offset) const;
  std::string text(int from, int to) const;
  std::vector<int> comments_in(int from, int to) const;

  // Reproduces a physical line exactly, except for replacing its leading
  // indentation with $new_indentation spaces.
  std::string reindent_line(int line_index, int new_indentation) const;

  // Reproduces a block comment while shifting every continuation line by the
  // same column delta as the first line. The returned text begins at the
  // comment delimiter and does not include indentation before its first line.
  std::string shift_multiline_comment(int comment_id,
                                      int new_start_column) const;

  // Reproduces complete physical lines while shifting every line by the same
  // indentation delta.
  std::string reindent_region(int first_line,
                              int last_line,
                              int new_first_indentation) const;

 private:
  void build_lines();
  void build_comments(List<Scanner::Comment> comments);

  Source* source_;
  std::vector<FormatLine> lines_;
  std::vector<FormatComment> comments_;
};

// Shared exactly-once consumption state for one formatting run.
class FormatCommentState {
 public:
  explicit FormatCommentState(const FormatSource* source);

  const FormatSource* source() const { return source_; }
  bool consumed(int id) const { return consumed_[id]; }
  void consume(int id);

  std::vector<int> unconsumed_in(int from, int to) const;
  bool has_unconsumed_in(int from, int to) const;
  bool all_consumed() const;

  // Renders own-line comments in source order, shifting their original
  // columns by $indentation_delta. Inline comments belong to their syntax and
  // make this operation fail.
  bool render_own_line(int from,
                       int to,
                       int indentation_delta,
                       std::string* result);

  // Reproduces and consumes a closed physical-line region.
  std::string render_verbatim(int first_line,
                              int last_line,
                              int new_first_indentation);

 private:
  const FormatSource* source_;
  std::vector<bool> consumed_;
};

} // namespace compiler
} // namespace toit

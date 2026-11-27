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

#include "format_source.h"

#include <algorithm>
#include <utility>

namespace toit {
namespace compiler {

FormatSource::FormatSource(Source* source, List<Scanner::Comment> comments)
    : source_(source) {
  ASSERT(source_ != null);
  build_lines();
  build_comments(comments);
}

void FormatSource::build_lines() {
  const uint8* bytes = source_->text();
  int size = source_->size();
  int from = 0;
  while (from < size) {
    int content_to = from;
    while (content_to < size && bytes[content_to] != '\n' &&
           bytes[content_to] != '\r') {
      content_to++;
    }
    int to = content_to;
    if (to < size && bytes[to] == '\r') to++;
    if (to < size && bytes[to] == '\n') to++;

    int indentation = 0;
    while (from + indentation < content_to) {
      uint8 c = bytes[from + indentation];
      if (c != ' ' && c != '\t') break;
      indentation++;
    }
    FormatLine line;
    line.from = from;
    line.content_to = content_to;
    line.to = to;
    line.indentation = indentation;
    lines_.push_back(line);
    from = to;
  }
}

int FormatSource::line_index_at(int offset) const {
  ASSERT(offset >= 0 && offset <= source_->size());
  if (lines_.empty()) return -1;
  if (offset == source_->size()) return lines_.size() - 1;

  int low = 0;
  int high = lines_.size();
  while (low + 1 < high) {
    int middle = low + (high - low) / 2;
    if (lines_[middle].from <= offset) {
      low = middle;
    } else {
      high = middle;
    }
  }
  ASSERT(lines_[low].from <= offset && offset < lines_[low].to);
  return low;
}

std::string FormatSource::text(int from, int to) const {
  ASSERT(from >= 0 && from <= to && to <= source_->size());
  return std::string(
      reinterpret_cast<const char*>(source_->text()) + from, to - from);
}

void FormatSource::build_comments(List<Scanner::Comment> comments) {
  for (auto comment : comments) {
    if (!comment.is_valid()) continue;
    int from = source_->offset_in_source(comment.range().from());
    int to = source_->offset_in_source(comment.range().to());
    int start_line = line_index_at(from);
    int end_line = line_index_at(std::max(from, to - 1));
    const FormatLine& line = lines_[start_line];
    bool follows_code = false;
    for (int offset = line.from; offset < from; offset++) {
      uint8 c = source_->text()[offset];
      if (c != ' ' && c != '\t') {
        follows_code = true;
        break;
      }
    }

    int id = comments_.size();
    FormatComment fact;
    fact.id = id;
    fact.from = from;
    fact.to = to;
    fact.start_line = start_line;
    fact.end_line = end_line;
    fact.start_column = from - line.from;
    fact.is_block = comment.is_multiline();
    fact.is_toitdoc = comment.is_toitdoc();
    fact.spans_lines = start_line != end_line;
    fact.follows_code = follows_code;
    fact.text = text(from, to);
    comments_.push_back(std::move(fact));
    if (!comment.is_multiline() && follows_code) {
      ASSERT(lines_[start_line].trailing_line_comment < 0);
      lines_[start_line].trailing_line_comment = id;
    }
  }
}

std::string FormatSource::reindent_line(int line_index,
                                        int new_indentation) const {
  ASSERT(line_index >= 0 && line_index < static_cast<int>(lines_.size()));
  ASSERT(new_indentation >= 0);
  const FormatLine& line = lines_[line_index];
  return std::string(new_indentation, ' ') +
      text(line.from + line.indentation, line.to);
}

std::string FormatSource::shift_multiline_comment(
    int comment_id, int new_start_column) const {
  ASSERT(comment_id >= 0 &&
         comment_id < static_cast<int>(comments_.size()));
  ASSERT(new_start_column >= 0);
  const FormatComment& comment = comments_[comment_id];
  ASSERT(comment.is_block && comment.spans_lines);
  int delta = new_start_column - comment.start_column;

  std::string result;
  const std::string& input = comment.text;
  size_t cursor = 0;
  while (cursor < input.size()) {
    size_t newline = input.find_first_of("\r\n", cursor);
    if (newline == std::string::npos) {
      result.append(input, cursor, std::string::npos);
      break;
    }
    result.append(input, cursor, newline - cursor);
    if (input[newline] == '\r' && newline + 1 < input.size() &&
        input[newline + 1] == '\n') {
      result.append("\r\n");
      cursor = newline + 2;
    } else {
      result.push_back(input[newline]);
      cursor = newline + 1;
    }

    size_t indentation_end = cursor;
    while (indentation_end < input.size() &&
           (input[indentation_end] == ' ' ||
            input[indentation_end] == '\t')) {
      indentation_end++;
    }
    int indentation = indentation_end - cursor;
    int shifted = std::max(0, indentation + delta);
    result.append(shifted, ' ');
    cursor = indentation_end;
  }
  return result;
}

} // namespace compiler
} // namespace toit

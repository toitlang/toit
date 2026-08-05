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

#include "format_trivia.h"

#include "../top.h"
#include "sources.h"

#include <algorithm>
#include <cstring>

namespace toit {
namespace compiler {

namespace {

int offset(Source* source, Source::Position position) {
  return source->offset_in_source(position);
}

int line_start(const uint8* text, int from) {
  while (from > 0 && text[from - 1] != '\n') from--;
  return from;
}

int line_end(const uint8* text, int size, int from) {
  while (from < size && text[from] != '\n' && text[from] != '\r') from++;
  return from;
}

bool has_code_before(const uint8* text, int line_start, int comment_start) {
  for (int i = line_start; i < comment_start; i++) {
    if (text[i] != ' ' && text[i] != '\t') return true;
  }
  return false;
}

} // namespace

FormatTrivia::FormatTrivia(Source* source, List<Scanner::Comment> comments)
    : source_(source) {
  ASSERT(source != null);
  const uint8* text = source->text();
  for (Scanner::Comment scanner_comment : comments) {
    if (!scanner_comment.is_valid()) continue;
    int from = offset(source, scanner_comment.range().from());
    int to = offset(source, scanner_comment.range().to());
    ASSERT(0 <= from && from <= to && to <= source->size());
    int start = line_start(text, from);
    int end = line_end(text, source->size(), to);
    std::string raw(reinterpret_cast<const char*>(text) + from, to - from);
    comments_.push_back({
        from,
        to,
        start,
        end,
        from - start,
        !scanner_comment.is_multiline(),
        raw.find('\n') != std::string::npos ||
            raw.find('\r') != std::string::npos,
        has_code_before(text, start, from),
        std::move(raw),
    });
  }
  std::sort(comments_.begin(), comments_.end(),
            [](const Comment& left, const Comment& right) {
              return left.from < right.from;
            });
}

TriviaLowering::TriviaLowering(const FormatTrivia* trivia,
                               LayoutBuilder* layouts)
    : trivia_(trivia)
    , layouts_(layouts)
    , consumed_(trivia == null ? 0 : trivia->comments().size(), false) {
  ASSERT(layouts != null);
}

bool TriviaLowering::only_horizontal_space(int from, int to) const {
  ASSERT(trivia_ != null);
  const uint8* text = trivia_->source()->text();
  for (int i = from; i < to; i++) {
    if (text[i] != ' ' && text[i] != '\t') return false;
  }
  return true;
}

int TriviaLowering::first_line_comment(int from,
                                       int to,
                                       bool include_trailing_line) const {
  if (trivia_ == null) return -1;
  const uint8* text = trivia_->source()->text();
  int trailing_end = to;
  if (include_trailing_line) {
    trailing_end = line_end(text, trivia_->source()->size(), to);
  }
  const std::vector<FormatTrivia::Comment>& comments = trivia_->comments();
  for (int id = 0; id < static_cast<int>(comments.size()); id++) {
    const FormatTrivia::Comment& comment = comments[id];
    if (!comment.is_line_comment) continue;
    if (from <= comment.from && comment.from < trailing_end) return id;
  }
  return -1;
}

const FormatTrivia::Comment& TriviaLowering::comment(int id) const {
  ASSERT(trivia_ != null);
  ASSERT(0 <= id && id < static_cast<int>(trivia_->comments().size()));
  return trivia_->comments()[id];
}

int TriviaLowering::find_syntax(int from, int to, const char* syntax) const {
  ASSERT(trivia_ != null);
  int length = std::strlen(syntax);
  const uint8* text = trivia_->source()->text();
  for (int offset = from; offset + length <= to; offset++) {
    bool inside_comment = false;
    for (const FormatTrivia::Comment& comment : trivia_->comments()) {
      if (comment.from <= offset && offset < comment.to) {
        offset = comment.to - 1;
        inside_comment = true;
        break;
      }
    }
    if (inside_comment) continue;
    if (std::memcmp(text + offset, syntax, length) == 0) return offset;
  }
  return -1;
}

Layout* TriviaLowering::exact_multiline_text(
    const FormatTrivia::Comment& comment, int base_column) {
  std::vector<Layout*> parts;
  const std::string& text = comment.text;
  size_t start = 0;
  bool first = true;
  while (start <= text.size()) {
    size_t end = text.find('\n', start);
    bool has_newline = end != std::string::npos;
    if (!has_newline) end = text.size();
    size_t content_start = start;
    if (!first) {
      int removed = 0;
      while (content_start < end && removed < base_column &&
             (text[content_start] == ' ' || text[content_start] == '\t')) {
        content_start++;
        removed++;
      }
    }
    parts.push_back(
        layouts_->text(text.substr(content_start, end - content_start)));
    if (!has_newline) break;
    parts.push_back(layouts_->hardline());
    start = end + 1;
    first = false;
  }
  return layouts_->concat(std::move(parts));
}

Layout* TriviaLowering::verbatim_region(int from, int to) {
  ASSERT(trivia_ != null);
  ASSERT(0 <= from && from <= to && to <= trivia_->source()->size());
  const uint8* source_text = trivia_->source()->text();
  int base_start = line_start(source_text, from);
  int base_column = from - base_start;
  std::string raw(reinterpret_cast<const char*>(source_text) + from, to - from);
  FormatTrivia::Comment region = {
      from,
      to,
      base_start,
      to,
      base_column,
      false,
      raw.find('\n') != std::string::npos,
      false,
      std::move(raw),
  };
  for (int id = 0; id < static_cast<int>(trivia_->comments().size()); id++) {
    const FormatTrivia::Comment& comment = trivia_->comments()[id];
    if (from <= comment.from && comment.to <= to) consumed_[id] = true;
  }
  return exact_multiline_text(region, base_column);
}

Layout* TriviaLowering::inline_comment(int id) {
  ASSERT(trivia_ != null);
  ASSERT(0 <= id && id < static_cast<int>(trivia_->comments().size()));
  const FormatTrivia::Comment& comment = trivia_->comments()[id];
  ASSERT(!comment.is_line_comment);
  ASSERT(!comment.spans_lines);
  ASSERT(!consumed_[id]);
  consumed_[id] = true;
  return layouts_->text(comment.text);
}

Layout* TriviaLowering::take_inline_prefix(Layout* core, int from, int to) {
  if (trivia_ == null || from >= to) return core;
  std::vector<int> ids;
  int cursor = from;
  for (int id = 0; id < static_cast<int>(trivia_->comments().size()); id++) {
    const FormatTrivia::Comment& comment = trivia_->comments()[id];
    if (consumed_[id] || comment.from < from || comment.to > to) continue;
    if (comment.is_line_comment || comment.spans_lines ||
        !only_horizontal_space(cursor, comment.from)) {
      return core;
    }
    ids.push_back(id);
    cursor = comment.to;
  }
  if (ids.empty() || !only_horizontal_space(cursor, to)) return core;

  std::vector<Layout*> prefix;
  cursor = from;
  for (int id : ids) {
    const FormatTrivia::Comment& comment = trivia_->comments()[id];
    // The containing syntax owns the gap before a prefix. This fragment owns
    // only gaps between attached comments and the one before the core.
    if (!prefix.empty() && comment.from != cursor) {
      prefix.push_back(layouts_->text(" "));
    }
    prefix.push_back(inline_comment(id));
    cursor = comment.to;
  }
  if (cursor != to) prefix.push_back(layouts_->text(" "));
  prefix.push_back(core);
  return layouts_->concat(std::move(prefix));
}

Layout* TriviaLowering::take_inline_suffix(Layout* core, int from, int to) {
  if (trivia_ == null || from >= to) return core;
  std::vector<int> ids;
  int cursor = from;
  for (int id = 0; id < static_cast<int>(trivia_->comments().size()); id++) {
    const FormatTrivia::Comment& comment = trivia_->comments()[id];
    if (consumed_[id] || comment.from < from || comment.to > to) continue;
    if (comment.is_line_comment || comment.spans_lines ||
        !only_horizontal_space(cursor, comment.from)) {
      if (ids.empty()) return core;
      break;
    }
    ids.push_back(id);
    cursor = comment.to;
  }
  if (ids.empty()) return core;

  std::vector<Layout*> suffix = {core};
  cursor = from;
  for (int id : ids) {
    const FormatTrivia::Comment& comment = trivia_->comments()[id];
    if (comment.from != cursor) suffix.push_back(layouts_->text(" "));
    suffix.push_back(inline_comment(id));
    cursor = comment.to;
  }
  return layouts_->concat(std::move(suffix));
}

Layout* TriviaLowering::take_own_line_block(int id) {
  ASSERT(trivia_ != null);
  ASSERT(0 <= id && id < static_cast<int>(trivia_->comments().size()));
  const FormatTrivia::Comment& comment = trivia_->comments()[id];
  ASSERT(!comment.is_line_comment);
  ASSERT(!comment.has_code_before);
  ASSERT(!consumed_[id]);
  consumed_[id] = true;
  return exact_multiline_text(comment, comment.original_column);
}

bool TriviaLowering::all_comments_consumed() const {
  for (bool consumed : consumed_) {
    if (!consumed) return false;
  }
  return true;
}

} // namespace compiler
} // namespace toit

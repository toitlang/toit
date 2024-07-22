// Copyright (C) 2024 Toitware ApS.
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

#include <string>

#include "ast.h"
#include "comments.h"

namespace toit {
namespace compiler {

int CommentsManager::find_closest_before(ast::Node* node) {
  auto node_range = node->full_range();
  if (comments_.is_empty()) return -1;
  if (node_range.is_before(comments_[0].range())) return -1;
  if (comments_.last().range().is_before(node_range)) return comments_.length() - 1;

  if (comments_[last_index_].range().is_before(node_range) &&
      node_range.is_before(comments_[last_index_ + 1].range())) {
    return last_index_;
  }
  int start = 0;
  int end = comments_.length() - 1;
  while (start < end) {
    int mid = start + (end - start) / 2;
    if (comments_[mid].range().is_before(node_range)) {
      if (node_range.is_before(comments_[mid + 1].range())) {
        return mid;
      }
      start = mid + 1;
    } else {
      end = mid;
    }
  }
  return -1;
}

bool CommentsManager::is_attached(Source::Range previous, Source::Range next) {
  // Check that there is one newline, and otherwise only whitespace.
  int start_offset = source_->offset_in_source(previous.to());
  int end_offset = source_->offset_in_source(next.from());
  int i = start_offset;
  auto text = source_->text();
  while (i < end_offset and text[i] == ' ') i++;
  if (i == end_offset) return true;
  if (text[i] == '\r') i++;
  if (i == end_offset) return true;
  if (text[i++] != '\n') return false;
  while (i < end_offset and text[i] == ' ') i++;
  if (i == end_offset) return true;
  return false;
}

bool CommentsManager::is_sorted(List<Scanner::Comment> comments) {
  for (int i = 1; i < comments.length(); i++) {
    if (!comments[i - 1].range().from().is_before(comments[i].range().from())) {
      return false;
    }
  }
  return true;
}

} // namespace toit::compiler
} // namespace toit

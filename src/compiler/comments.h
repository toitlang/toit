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

#pragma once

#include "../top.h"

#include "list.h"
#include "scanner.h"
#include "sources.h"

namespace toit {
namespace compiler {

namespace ast {
class Node;
}

class CommentsManager {
 public:
  CommentsManager(List<Scanner::Comment> comments, Source* source)
      : comments_(comments)
      , source_(source) {
    ASSERT(is_sorted(comments));
  }

  int find_closest_before(ast::Node* node);
  bool is_attached(int index1, int index2) {
    return is_attached(comments_[index1].range(), comments_[index2].range());
  }
  bool is_attached(Source::Range previous, Source::Range next);

  bool is_attached(int index, Source::Range next) {
    return is_attached(comments_[index].range(), next);
  }

  Source::Range comment_range(int index) {
    return comments_[index].range();
  }

 protected:
  List<Scanner::Comment> comments_;
  Source* source_;

  int last_index_ = 0;

  static bool is_sorted(List<Scanner::Comment> comments);
};

} // namespace toit::compiler
} // namespace toit

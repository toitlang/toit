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

static Source::Range compute_outline_range(ast::Node* node, CommentsManager& manager) {
  int earliest_comment = manager.find_closest_before(node);
  auto full_range = node->full_range();
  if (earliest_comment == -1 || !manager.is_attached(earliest_comment, full_range)) {
    return full_range;
  }
  // Walk up the comments as long as they are attached. This handles "//"
  // comments and multiple /**/ comments, like a Toitdoc followed by
  // another comment.
  while (earliest_comment > 1 &&
          manager.is_attached(earliest_comment - 1, earliest_comment)) {
    earliest_comment--;
  }
  auto earliest_range = manager.comment_range(earliest_comment);
  return earliest_range.extend(full_range);
}

void set_outline_ranges(ast::Unit* unit, List<Scanner::Comment> comments) {
  CommentsManager manager(comments, unit->source());

  for (auto declaration : unit->declarations()) {
    auto outline_range = compute_outline_range(declaration, manager);
    if (declaration->is_Declaration()) {
      declaration->as_Declaration()->set_outline_range(outline_range);
    } else if (declaration->is_Class()) {
      auto klass = declaration->as_Class();
      klass->set_outline_range(outline_range);
      for (auto member : klass->members()) {
        member->set_outline_range(compute_outline_range(member, manager));
      }
    } else {
      UNREACHABLE();
    }
  }
}

} // namespace toit::compiler
} // namespace toit

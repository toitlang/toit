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

void set_outline_ranges(ast::Unit* unit, List<Scanner::Comment> comments) {
  CommentsManager manager(comments, unit->source());

  for (auto declaration : unit->declarations()) {
    if (declaration->is_Declaration()) {
      int closest = manager.find_closest_before(declaration);
      if (closest == -1) continue;
      if (!manager.is_attached(closest, closest + 1)) continue;
      auto toitdoc = comments_manager.find_for(declaration);
      declaration->as_Declaration()->set_toitdoc(toitdoc);
    } else {
      ASSERT(declaration->is_Class());
      auto klass = declaration->as_Class();
      auto toitdoc = comments_manager.find_for(klass);
      klass->set_toitdoc(toitdoc);
      for (auto member : klass->members()) {
        auto member_toitdoc = comments_manager.find_for(member);
        member->set_toitdoc(member_toitdoc);
      }
    }
  }
}

} // namespace toit::compiler
} // namespace toit

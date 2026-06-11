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
#include <unordered_map>
#include <vector>

#include "ast.h"
#include "scanner.h"

namespace toit {
namespace compiler {

// One comment, routed to an AST node. `text` is the raw source bytes
// including the comment delimiters; for multi-line `/* */` comments it
// spans multiple lines.
struct CommentTrivia {
  bool is_multiline = false;       // `/* */` (may still be single-line).
  bool spans_lines = false;        // Contains a newline.
  std::string text;
  // Blank lines between the previous entity (node or comment) and this
  // comment.
  int blank_lines_before = 0;
  // Source column of the first character; used to delta-shift the
  // interior lines of line-spanning comments when their indentation
  // changes.
  int original_column = 0;
  // The comment was glued to the previous token (`List/*<int>*/`);
  // rendered without a gap so it stays part of what it annotates.
  bool attached = false;
};

struct NodeTrivia {
  // Comments on their own lines before the node.
  std::vector<CommentTrivia> leading;
  // Comments after the node's last token, on the same line.
  std::vector<CommentTrivia> trailing;
  // Comments at the end of the node's child list, after the last
  // child (only set on list-owning nodes).
  std::vector<CommentTrivia> dangling;
  // Blank lines between the previous sibling (or the last leading
  // comment) and the node itself.
  int blank_lines_before = 0;
  // The node contains a comment at a position the printer has no slot
  // for (inside an expression, between tokens). The whole statement is
  // reproduced verbatim from source. This is the formatter's only
  // escape hatch.
  bool frozen = false;
};

// Side table mapping AST nodes to their attached trivia. The AST stays
// untouched.
class TriviaTable {
 public:
  // Null when the node has no trivia.
  const NodeTrivia* find(ast::Node* node) const {
    auto it = map_.find(node);
    return it == map_.end() ? null : &it->second;
  }

  NodeTrivia* get(ast::Node* node) { return &map_[node]; }

  bool is_frozen(ast::Node* node) const {
    auto it = map_.find(node);
    return it != map_.end() && it->second.frozen;
  }

 private:
  std::unordered_map<ast::Node*, NodeTrivia> map_;
};

// Routes every comment and blank-line run in the unit to an AST node.
// After this pass, layout never needs to look at source bytes for
// trivia decisions.
void attach_trivia(ast::Unit* unit,
                   Source* source,
                   List<Scanner::Comment> comments,
                   TriviaTable* table);

} // namespace toit::compiler
} // namespace toit

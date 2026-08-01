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
  // Stable index in source order. Used to prove that every comment is
  // rendered exactly once.
  int id = -1;
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

// Trivia in a syntactic gap that has no AST node of its own. The first
// consumer is map entries, whose ':' token is not represented in the AST.
struct GapTrivia {
  std::vector<CommentTrivia> comments;
};

struct MapEntryTrivia {
  GapTrivia before_colon;
  GapTrivia after_colon;
};

struct NodeTrivia {
  // Comments on their own lines before the node.
  std::vector<CommentTrivia> leading;
  // Comments after the node's last token, on the same line.
  std::vector<CommentTrivia> trailing;
  // Comments at the end of the node's child list, after the last
  // child (only set on list-owning nodes).
  std::vector<CommentTrivia> dangling;
  // End-of-line comments immediately after an opening collection
  // delimiter, before the first child.
  GapTrivia after_open;
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

  MapEntryTrivia* get_map_entry(ast::Expression* key) {
    return &map_entries_[key];
  }

  const MapEntryTrivia* find_map_entry(ast::Expression* key) const {
    auto it = map_entries_.find(key);
    return it == map_entries_.end() ? null : &it->second;
  }

  bool is_frozen(ast::Node* node) const {
    auto it = map_.find(node);
    return it != map_.end() && it->second.frozen;
  }

  void set_preamble(std::string preamble) {
    preamble_ = std::move(preamble);
  }
  const std::string& preamble() const { return preamble_; }

  void initialize_comment_ranges(std::vector<std::pair<int, int>> ranges) {
    comment_ranges_ = std::move(ranges);
    emitted_.assign(comment_ranges_.size(), false);
  }

  void mark_emitted(int id);

  std::vector<int> comment_ids_in_range(int from, int to) const {
    std::vector<int> result;
    for (int id = 0; id < static_cast<int>(comment_ranges_.size()); id++) {
      auto range = comment_ranges_[id];
      if (from <= range.first && range.second <= to) result.push_back(id);
    }
    return result;
  }

  bool all_comments_emitted() const;

 private:
  std::unordered_map<ast::Node*, NodeTrivia> map_;
  std::unordered_map<ast::Expression*, MapEntryTrivia> map_entries_;
  std::string preamble_;
  std::vector<std::pair<int, int>> comment_ranges_;
  std::vector<bool> emitted_;
  bool duplicate_emission_ = false;
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

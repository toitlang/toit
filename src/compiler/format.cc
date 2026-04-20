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

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../top.h"
#include "format.h"
#include "ast.h"
#include "sources.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

// Walks the AST top-level nodes in source order, emitting the source bytes
// for each node plus the surrounding whitespace/comments. Output is
// byte-identical to the input at M1; the structure exists so M2+ can diverge
// per-node.
class Formatter {
 public:
  Formatter(Unit* unit, List<Scanner::Comment> comments)
      : unit_(unit)
      , source_(unit->source())
      , comments_(comments) {}

  uint8* take_output(int* size_out) {
    *size_out = output_.size();
    uint8* buf = unvoid_cast<uint8*>(malloc(output_.size()));
    memcpy(buf, output_.data(), output_.size());
    return buf;
  }

  void format() {
    std::vector<Node*> top;
    top.reserve(unit_->imports().length()
                + unit_->exports().length()
                + unit_->declarations().length());
    for (auto n : unit_->imports()) top.push_back(n);
    for (auto n : unit_->exports()) top.push_back(n);
    for (auto n : unit_->declarations()) top.push_back(n);
    std::sort(top.begin(), top.end(), [this](Node* a, Node* b) {
      return pos(a->full_range().from()) < pos(b->full_range().from());
    });

    for (Node* node : top) {
      visit_top_level(node);
    }
    // Trailing whitespace / comments at end of file.
    advance_to(source_->size());
  }

 private:
  Unit* unit_;
  Source* source_;
  List<Scanner::Comment> comments_;
  std::string output_;
  int source_cursor_ = 0;

  int pos(Source::Position p) const { return source_->offset_in_source(p); }

  void emit_source(int from, int to) {
    if (from < to) {
      output_.append(reinterpret_cast<const char*>(source_->text()) + from,
                     to - from);
    }
  }

  void advance_to(int to) {
    emit_source(source_cursor_, to);
    source_cursor_ = to;
  }

  void visit_top_level(Node* node) {
    int start = pos(node->full_range().from());
    int end = pos(node->full_range().to());
    // Preceding trivia (whitespace, blank lines, comments).
    advance_to(start);
    // The node itself — verbatim at M1.
    advance_to(end);
  }
};

}  // namespace

uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  Formatter formatter(unit, comments);
  formatter.format();
  return formatter.take_output(formatted_size);
}

} // namespace toit::compiler
} // namespace toit

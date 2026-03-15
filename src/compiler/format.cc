// Copyright (C) 2025 Toit contributors.
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

#include "../top.h"
#include "format.h"
#include "ast.h"

namespace toit {
namespace compiler {

using namespace ast;

/// A copy formatter that reproduces the original source exactly.
///
/// Uses a cursor-based approach: walks the AST via TraversingVisitor, and for
/// each leaf node, emits all source text from the current cursor position
/// through the end of that node. Gaps between nodes (whitespace, comments,
/// keywords, operators) are captured naturally.
class CopyFormatter : public TraversingVisitor {
 public:
  explicit CopyFormatter(Source* source, List<Scanner::Comment> comments)
      : source_(source), comments_(comments) {}

  std::string format(Unit* unit) {
    cursor_ = 0;
    output_.clear();
    for (auto node : unit->imports()) node->accept(this);
    for (auto node : unit->exports()) node->accept(this);
    for (auto node : unit->declarations()) node->accept(this);
    // Emit any trailing content (final newline, trailing comments).
    emit_to(source_->size());
    return output_;
  }

 private:
  Source* source_;
  List<Scanner::Comment> comments_;
  int cursor_ = 0;
  std::string output_;

  int offset(Source::Position pos) {
    return source_->offset_in_source(pos);
  }

  /// Emits source text from the current cursor up to (not including) the
  /// given byte offset.
  void emit_to(int pos) {
    if (pos > cursor_) {
      auto text = source_->text();
      output_.append(reinterpret_cast<const char*>(text) + cursor_, pos - cursor_);
      cursor_ = pos;
    }
  }

  /// Emits source text from the current cursor through the end of the
  /// given node's full range.
  void emit_through(Node* node) {
    emit_to(offset(node->full_range().to()));
  }

  // ---- Leaf nodes: advance cursor through them ----

  void visit_Import(Import* node) override { emit_through(node); }
  void visit_Export(Export* node) override { emit_through(node); }
  void visit_Expression(Expression* node) override { emit_through(node); }
  void visit_Error(Error* node) override { emit_through(node); }
  void visit_Identifier(Identifier* node) override { emit_through(node); }
  void visit_LspSelection(LspSelection* node) override { emit_through(node); }
  void visit_LiteralNull(LiteralNull* node) override { emit_through(node); }
  void visit_LiteralUndefined(LiteralUndefined* node) override { emit_through(node); }
  void visit_LiteralBoolean(LiteralBoolean* node) override { emit_through(node); }
  void visit_LiteralInteger(LiteralInteger* node) override { emit_through(node); }
  void visit_LiteralCharacter(LiteralCharacter* node) override { emit_through(node); }
  void visit_LiteralString(LiteralString* node) override { emit_through(node); }
  void visit_LiteralFloat(LiteralFloat* node) override { emit_through(node); }
  void visit_TokenNode(TokenNode* node) override { emit_through(node); }

  // ---- Non-leaf nodes with source-order fixes ----

  // TraversingVisitor visits return_type before parameters, but in Toit
  // source parameters come before the return type:
  //   foo x/int -> int:
  void visit_Method(Method* node) override {
    visit_Declaration(node);  // name_or_dot
    for (int i = 0; i < node->parameters().length(); i++) {
      node->parameters()[i]->accept(this);
    }
    if (node->return_type() != null) node->return_type()->accept(this);
    if (node->body() != null) {
      node->body()->accept(this);
    }
  }

  // TraversingVisitor visits handler before handler_parameters, but in Toit
  // source handler_parameters come first:
  //   try: body finally: | e | handler
  void visit_TryFinally(TryFinally* node) override {
    node->body()->accept(this);
    for (auto parameter : node->handler_parameters()) {
      parameter->accept(this);
    }
    node->handler()->accept(this);
  }

  // All other non-leaf nodes use TraversingVisitor defaults, which visit
  // children in source order.
};

uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  CopyFormatter formatter(unit->source(), comments);
  std::string output = formatter.format(unit);

  uint8* formatted = reinterpret_cast<uint8*>(strdup(output.c_str()));
  *formatted_size = output.size();
  return formatted;
}

} // namespace toit::compiler
} // namespace toit

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
#include "token.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace format {

class Printer {
 public:
  /// The break_width is the flat_width threshold above which a Group breaks.
  explicit Printer(int break_width = 100) : break_width_(break_width) {}

  std::string print(Document* doc) {
    output_.clear();
    current_column_ = 0;
    print_doc(doc, 0, false);
    return output_;
  }

 private:
  int break_width_;
  int current_column_;
  std::string output_;

  void print_doc(Document* doc, int indent, bool broken) {
    if (doc == null) return;
    switch (doc->type()) {
      case Document::TEXT: {
        auto text = static_cast<Text*>(doc);
        output_ += text->text();
        // Track column: if text contains newlines, column resets.
        auto& t = text->text();
        auto pos = t.rfind('\n');
        if (pos != std::string::npos) {
          current_column_ = t.length() - pos - 1;
        } else {
          current_column_ += t.length();
        }
        break;
      }
      case Document::LINE: {
        auto line = static_cast<Line*>(doc);
        if (broken || line->kind() == Line::HARD) {
          output_ += "\n";
          output_ += std::string(indent, ' ');
          current_column_ = indent;
        } else {
          output_ += " ";
          current_column_ += 1;
        }
        break;
      }
      case Document::CONCAT: {
        auto concat = static_cast<Concat*>(doc);
        for (auto child : concat->children()) {
          print_doc(child, indent, broken);
        }
        break;
      }
      case Document::GROUP: {
        auto group = static_cast<Group*>(doc);
        bool should_break = group->flat_width() > break_width_;
        for (auto child : group->children()) {
          print_doc(child, indent, should_break);
        }
        break;
      }
      case Document::INDENT: {
        auto ind = static_cast<Indent*>(doc);
        print_doc(ind->child(), indent + ind->amount(), broken);
        break;
      }
    }
  }
};

} // namespace format

/// Builds a Document IR tree from the AST.
///
/// Uses a cursor-based approach to capture source text. For nodes without
/// specific formatting rules, the original source text (including whitespace
/// and comments) is captured as Text nodes. For nodes with formatting rules
/// (e.g., Binary), proper IR structure (Groups, Lines) is emitted.
class FormattingVisitor : public Visitor {
 public:
  explicit FormattingVisitor(Source* source, List<Scanner::Comment> comments)
      : source_(source), comments_(comments) {}

  format::Document* format(Unit* unit) {
    cursor_ = 0;
    ListBuilder<format::Document*> top_docs;
    docs_ = &top_docs;
    for (auto node : unit->imports()) node->accept(this);
    for (auto node : unit->exports()) node->accept(this);
    for (auto node : unit->declarations()) node->accept(this);
    emit_to(source_->size());
    return new format::Concat(top_docs.build());
  }

 private:
  Source* source_;
  List<Scanner::Comment> comments_;
  int cursor_ = 0;
  ListBuilder<format::Document*>* docs_ = null;

  int offset(Source::Position pos) {
    return source_->offset_in_source(pos);
  }

  /// Returns the byte offset where a node truly starts in the source.
  ///
  /// Some nodes' full_range() doesn't cover their leading children
  /// (e.g., Index/IndexSlice don't include their receiver in full_range).
  /// This also affects any parent whose full_range is computed from such
  /// children (e.g., Binary whose left is an Index).
  /// We recursively follow the "first child" chain to find the true start.
  int node_start(Node* node) {
    if (node->is_Index()) return node_start(node->as_Index()->receiver());
    if (node->is_IndexSlice()) return node_start(node->as_IndexSlice()->receiver());
    if (node->is_Binary()) return node_start(node->as_Binary()->left());
    if (node->is_Dot()) return node_start(node->as_Dot()->receiver());
    if (node->is_Call()) return node_start(node->as_Call()->target());
    if (node->is_Unary() && !node->as_Unary()->prefix()) {
      return node_start(node->as_Unary()->expression());
    }
    return offset(node->full_range().from());
  }

  /// Emits source text from cursor to pos as a Text node.
  void emit_to(int pos) {
    if (pos > cursor_) {
      auto text = source_->text();
      std::string s(reinterpret_cast<const char*>(text) + cursor_, pos - cursor_);
      docs_->add(new format::Text(s));
      cursor_ = pos;
    }
  }

  /// Emits source text from cursor through end of node.
  void emit_through(Node* node) {
    emit_to(offset(node->full_range().to()));
  }

  /// Builds a sub-document for a node (creates a new docs_ scope).
  /// After the visit, emits any remaining text up to the node's end.
  format::Document* build(Node* node) {
    if (node == null) return null;
    ListBuilder<format::Document*> child_docs;
    auto saved = docs_;
    docs_ = &child_docs;
    node->accept(this);
    // Capture any trailing text not covered by children.
    emit_to(offset(node->full_range().to()));
    docs_ = saved;
    auto children = child_docs.build();
    if (children.length() == 0) return new format::Text("");
    if (children.length() == 1) return children[0];
    return new format::Concat(children);
  }

  // ==== Leaf nodes: emit source text from cursor through end of node ====

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

  // ==== Non-leaf nodes: recurse into children in source order ====
  // These are "structural" — they just recurse so that formatting
  // can kick in for children that have specific rules.

  void visit_Class(Class* node) override {
    node->name()->accept(this);
    if (node->has_super()) node->super()->accept(this);
    for (auto member : node->members()) member->accept(this);
  }

  void visit_Declaration(Declaration* node) override {
    node->name_or_dot()->accept(this);
  }

  void visit_Field(Field* node) override {
    visit_Declaration(node);
    if (node->initializer() != null) node->initializer()->accept(this);
  }

  void visit_Method(Method* node) override {
    visit_Declaration(node);
    for (int i = 0; i < node->parameters().length(); i++) {
      node->parameters()[i]->accept(this);
    }
    if (node->return_type() != null) node->return_type()->accept(this);
    if (node->body() != null) node->body()->accept(this);
  }

  void visit_NamedArgument(NamedArgument* node) override {
    node->name()->accept(this);
    if (node->expression() != null) node->expression()->accept(this);
  }

  void visit_BreakContinue(BreakContinue* node) override {
    if (node->label() != null) node->label()->accept(this);
    if (node->value() != null) node->value()->accept(this);
  }

  void visit_Parenthesis(Parenthesis* node) override {
    node->expression()->accept(this);
  }

  void visit_Block(Block* node) override {
    for (int i = 0; i < node->parameters().length(); i++) {
      node->parameters()[i]->accept(this);
    }
    if (node->body() != null) node->body()->accept(this);
  }

  void visit_Lambda(Lambda* node) override {
    for (int i = 0; i < node->parameters().length(); i++) {
      node->parameters()[i]->accept(this);
    }
    if (node->body() != null) node->body()->accept(this);
  }

  void visit_Sequence(Sequence* node) override {
    for (auto expr : node->expressions()) expr->accept(this);
  }

  void visit_DeclarationLocal(DeclarationLocal* node) override {
    node->name()->accept(this);
    if (node->type() != null) node->type()->accept(this);
    if (node->value() != null) node->value()->accept(this);
  }

  void visit_If(If* node) override {
    node->expression()->accept(this);
    node->yes()->accept(this);
    if (node->no() != null) node->no()->accept(this);
  }

  void visit_While(While* node) override {
    node->condition()->accept(this);
    node->body()->accept(this);
  }

  void visit_For(For* node) override {
    if (node->initializer() != null) node->initializer()->accept(this);
    if (node->condition() != null) node->condition()->accept(this);
    if (node->update() != null) node->update()->accept(this);
    node->body()->accept(this);
  }

  void visit_TryFinally(TryFinally* node) override {
    node->body()->accept(this);
    for (auto parameter : node->handler_parameters()) {
      parameter->accept(this);
    }
    node->handler()->accept(this);
  }

  void visit_Return(Return* node) override {
    if (node->value() != null) node->value()->accept(this);
  }

  void visit_Unary(Unary* node) override {
    node->expression()->accept(this);
  }

  void visit_Binary(Binary* node) override {
    // Check if the binary expression spans multiple lines in the source.
    int start = node_start(node->left());
    int end = offset(node->full_range().to());
    bool spans_lines = false;
    auto src = source_->text();
    for (int i = start; i < end; i++) {
      if (src[i] == '\n') { spans_lines = true; break; }
    }

    if (!spans_lines) {
      // Already on one line — preserve original formatting.
      node->left()->accept(this);
      node->right()->accept(this);
      return;
    }

    // Multi-line binary. Try to flatten onto one line.
    emit_to(start);
    int cursor_before = cursor_;

    auto left_doc = build(node->left());
    cursor_ = node_start(node->right());
    auto right_doc = build(node->right());

    std::string op_str(Token::symbol(node->kind()).c_str());
    int flat_width = left_doc->flat_width() + 1 + op_str.length() + 1 + right_doc->flat_width();

    if (flat_width < format::FLAT_WIDTH_MAX && flat_width <= 100) {
      // Fits on one line — flatten.
      docs_->add(left_doc);
      docs_->add(new format::Text(" " + op_str + " "));
      docs_->add(right_doc);
    } else {
      // Too wide to flatten. Preserve original formatting.
      cursor_ = cursor_before;
      emit_through(node);
    }
  }

  void visit_Call(Call* node) override {
    node->target()->accept(this);
    for (auto arg : node->arguments()) arg->accept(this);
  }

  void visit_Dot(Dot* node) override {
    node->receiver()->accept(this);
    node->name()->accept(this);
  }

  void visit_Index(Index* node) override {
    node->receiver()->accept(this);
    for (auto arg : node->arguments()) arg->accept(this);
  }

  void visit_IndexSlice(IndexSlice* node) override {
    node->receiver()->accept(this);
    if (node->from() != null) node->from()->accept(this);
    if (node->to() != null) node->to()->accept(this);
  }

  void visit_Nullable(Nullable* node) override {
    node->type()->accept(this);
  }

  void visit_Parameter(Parameter* node) override {
    node->name()->accept(this);
    if (node->type() != null) node->type()->accept(this);
    if (node->default_value() != null) node->default_value()->accept(this);
  }

  void visit_LiteralStringInterpolation(LiteralStringInterpolation* node) override {
    for (int i = 0; i < node->parts().length(); i++) {
      if (i != 0) {
        node->expressions()[i - 1]->accept(this);
        if (node->formats()[i - 1] != null) {
          node->formats()[i - 1]->accept(this);
        }
      }
      node->parts()[i]->accept(this);
    }
  }

  void visit_LiteralList(LiteralList* node) override {
    for (auto elem : node->elements()) elem->accept(this);
  }

  void visit_LiteralByteArray(LiteralByteArray* node) override {
    for (auto elem : node->elements()) elem->accept(this);
  }

  void visit_LiteralSet(LiteralSet* node) override {
    for (auto elem : node->elements()) elem->accept(this);
  }

  void visit_LiteralMap(LiteralMap* node) override {
    for (int i = 0; i < node->keys().length(); i++) {
      node->keys()[i]->accept(this);
      node->values()[i]->accept(this);
    }
  }

  void visit_ToitdocReference(ToitdocReference* node) override {
    node->target()->accept(this);
    for (auto parameter : node->parameters()) {
      parameter->accept(this);
    }
  }
};

uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  FormattingVisitor visitor(unit->source(), comments);
  format::Document* doc = visitor.format(unit);
  format::Printer printer;
  std::string output = printer.print(doc);

  uint8* formatted = reinterpret_cast<uint8*>(strdup(output.c_str()));
  *formatted_size = output.size();
  return formatted;
}

} // namespace toit::compiler
} // namespace toit

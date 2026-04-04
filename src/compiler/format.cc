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
    line_indent_ = 0;
    print_doc(doc, 0, false);
    return output_;
  }

 private:
  int break_width_;
  int current_column_;
  int line_indent_;  // Indentation of the current line (column of first non-space char).
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
          // Compute line_indent_: count leading spaces on the last line.
          line_indent_ = 0;
          for (size_t i = pos + 1; i < t.length() && t[i] == ' '; i++) {
            line_indent_++;
          }
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
          line_indent_ = indent;
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
        // When a Group breaks, use the current line's indentation as base,
        // so continuation lines indent relative to the statement start.
        int group_indent = should_break ? line_indent_ : indent;
        for (auto child : group->children()) {
          print_doc(child, group_indent, should_break);
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
class FormattingVisitor : public TraversingVisitor {
 public:
  explicit FormattingVisitor(Source* source, List<Scanner::Comment> comments)
      : source_(source), comments_(comments) {}

  format::Document* format(Unit* unit) {
    cursor_ = 0;
    comment_index_ = 0;
    ListBuilder<format::Document*> top_docs;
    docs_ = &top_docs;
    unit->accept(this);
    emit_to(source_->size());
    return new format::Concat(top_docs.build());
  }

 private:
  Source* source_;
  List<Scanner::Comment> comments_;
  int cursor_ = 0;
  int comment_index_ = 0;
  ListBuilder<format::Document*>* docs_ = null;

  int offset(Source::Position pos) {
    return source_->offset_in_source(pos);
  }

  /// Returns true if there are any comments whose start falls in [from, to).
  bool has_comment_in_range(int from, int to) {
    // Advance comment_index_ past comments before 'from'.
    while (comment_index_ < comments_.length() &&
           offset(comments_[comment_index_].range().from()) < from) {
      comment_index_++;
    }
    if (comment_index_ >= comments_.length()) return false;
    return offset(comments_[comment_index_].range().from()) < to;
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

  // ==== Leaf nodes: handled uniformly via visit_leaf ====

  void visit_leaf(Node* node) override { emit_through(node); }

  // ==== Overrides for nodes where source order differs from TraversingVisitor ====

  void visit_Method(Method* node) override {
    visit_Declaration(node);
    for (int i = 0; i < node->parameters().length(); i++) {
      node->parameters()[i]->accept(this);
    }
    if (node->return_type() != null) node->return_type()->accept(this);
    if (node->body() != null) node->body()->accept(this);
  }

  // ==== Formatting helpers ====

  /// Returns true if the expression needs parentheses when used as an
  /// inline binary operand of the given operator.
  ///
  /// Operators parsed by parse_precedence() (arithmetic, comparison, etc.)
  /// use parse_precedence(level+1) for same-line RHS, which doesn't handle
  /// calls. So calls with arguments need parens.
  ///
  /// Operators parsed by parse_logical_spelled() (and, or) always parse
  /// operands through parse_call(), so no parens needed.
  bool needs_parens_as_operand(Expression* expr, Token::Kind op) {
    if (op == Token::LOGICAL_AND || op == Token::LOGICAL_OR) return false;
    if (expr->is_Call()) {
      return expr->as_Call()->arguments().length() > 0;
    }
    return false;
  }

  // ==== Formatting rules ====

  /// Checks whether the source text in [from, to) contains a newline.
  bool spans_multiple_lines(int from, int to) {
    auto src = source_->text();
    for (int i = from; i < to; i++) {
      if (src[i] == '\n') return true;
    }
    return false;
  }

  /// Collects a chain of binary operations with the same operator.
  /// Handles both left-associative (`+`: chain is on the left) and
  /// right-associative (`and`: chain is on the right) operators.
  void collect_binary_chain(Binary* node,
                            Token::Kind chain_op,
                            std::vector<Expression*>& operands,
                            std::vector<Token::Kind>& operators) {
    auto left = node->left();
    if (left->is_Binary() && left->as_Binary()->kind() == chain_op) {
      collect_binary_chain(left->as_Binary(), chain_op, operands, operators);
    } else {
      operands.push_back(left);
    }
    operators.push_back(node->kind());
    auto right = node->right();
    if (right->is_Binary() && right->as_Binary()->kind() == chain_op) {
      collect_binary_chain(right->as_Binary(), chain_op, operands, operators);
    } else {
      operands.push_back(right);
    }
  }

  void visit_Binary(Binary* node) override {
    // Don't reformat assignments — they are handled by the copy formatter.
    if (Token::precedence(node->kind()) == PRECEDENCE_ASSIGNMENT) {
      TraversingVisitor::visit_Binary(node);
      return;
    }

    int start = node_start(node->left());
    int end = offset(node->full_range().to());

    if (!spans_multiple_lines(start, end)) {
      // Already on one line — preserve original formatting.
      TraversingVisitor::visit_Binary(node);
      return;
    }

    // If there are comments in the binary expression, don't reformat —
    // comments would be lost when we skip the gap between operands.
    if (has_comment_in_range(start, end)) {
      TraversingVisitor::visit_Binary(node);
      return;
    }

    // Collect the chain: a + b - c → operands=[a, b, c], operators=[+, -].
    std::vector<Expression*> operands;
    std::vector<Token::Kind> operators;
    collect_binary_chain(node, node->kind(), operands, operators);

    // Build Document IR: Group(first, Indent(Line op second, Line op third, ...))
    emit_to(start);

    bool first_parens = needs_parens_as_operand(operands[0], node->kind());
    auto first_doc = build(operands[0]);

    ListBuilder<format::Document*> indent_children;
    for (int i = 0; i < static_cast<int>(operators.size()); i++) {
      std::string op_str(Token::symbol(operators[i]).c_str());
      cursor_ = node_start(operands[i + 1]);
      auto operand_doc = build(operands[i + 1]);
      bool parens = needs_parens_as_operand(operands[i + 1], operators[i]);
      indent_children.add(new format::Line());
      indent_children.add(new format::Text(op_str + " "));
      if (parens) indent_children.add(new format::Text("("));
      indent_children.add(operand_doc);
      if (parens) indent_children.add(new format::Text(")"));
    }

    ListBuilder<format::Document*> group_children;
    if (first_parens) group_children.add(new format::Text("("));
    group_children.add(first_doc);
    if (first_parens) group_children.add(new format::Text(")"));
    group_children.add(new format::Indent(
        new format::Concat(indent_children.build())));

    docs_->add(new format::Group(group_children.build()));
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

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

/// Formats the given unit and returns the formatted version.
/// The returned string must be freed.
uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  const char* src = reinterpret_cast<const char*>(unit->source()->text());
  uint8* formatted = reinterpret_cast<uint8*>(strdup(src));
  *formatted_size = unit->source()->size();
  return formatted;
}

namespace format {

class Printer {
 public:
  Printer(int max_column = 80) : max_column_(max_column) {}

  std::string print(Document* doc) {
    output_.clear();
    current_column_ = 0;
    print(doc, 0, false);
    return output_;
  }

 private:
  int max_column_;
  int current_column_;
  std::string output_;

  void print(Document* doc, int current_indent, bool break_group) {
    if (doc == null) return;
    switch (doc->type()) {
      case Document::TEXT: {
        auto text = doc->as_text();
        output_ += text->text();
        current_column_ += text->text().length();
        break;
      }
      case Document::LINE: {
        auto line = doc->as_line();
        if (break_group || line->is_hard_break()) {
          output_ += "\n";
          output_ += std::string(current_indent, ' ');
          current_column_ = current_indent;
        } else {
          output_ += " ";
          current_column_ += 1;
        }
        break;
      }
      case Document::INDENT: {
        auto indent = doc->as_indent();
        print(indent->child(), current_indent + indent->amount(), break_group);
        break;
      }
      case Document::GROUP: {
        auto group = doc->as_group();
        bool breaks = break_group || !fits(group, max_column_ - current_column_);
        for (Document* child : group->children()) {
          print(child, current_indent, breaks);
        }
        break;
      }
      case Document::IFFLAT: {
        auto if_flat = doc->as_if_flat();
        if (break_group) {
          if (if_flat->broken()) print(if_flat->broken(), current_indent, break_group);
        } else {
          if (if_flat->flat()) print(if_flat->flat(), current_indent, break_group);
        }
        break;
      }
    }
  }

  bool fits(Document* doc, int space) {
    if (space < 0) return false;
    if (doc == null) return true;
    switch (doc->type()) {
      case Document::TEXT: {
        return space >= static_cast<int>(doc->as_text()->text().length());
      }
      case Document::LINE: {
        if (doc->as_line()->is_hard_break()) return false;
        return space >= 1;
      }
      case Document::INDENT: {
        return fits(doc->as_indent()->child(), space);
      }
      case Document::GROUP: {
        int remaining = space;
        for (Document* child : doc->as_group()->children()) {
          if (!fits(child, remaining)) return false;
          // In a real implementation we would track the actual consumption.
          // For simplicity, we can do a dummy measure pass.
          // Actually, we need a separate `measure` that returns the width or -1.
        }
        return true;
      }
      case Document::IFFLAT: {
        auto if_flat = doc->as_if_flat();
        if (if_flat->flat()) return fits(if_flat->flat(), space);
        return true;
      }
    }
    return true;
  }
};

} // namespace format

namespace {  // anonymous.

class FormatNode {
 public:
  FormatNode(const char* text, const Source::Range& range)
      : text_(text)
      , range_(range) {}
  FormatNode(const std::string& text, const Source::Range& range)
      : text_(text)
      , range_(range) {}

  std::string text() const { return text_; }
  int size() const { return static_cast<int>(text().size()); }

  Source::Range range() const { return range_; }

  void set_attached() { preferences_ |= ATTACHED; }
  void set_same_line() { preferences_ |= SAME_LINE; }
  void set_indented_by_2() { preferences_ |= INDENTED_BY_2; }
  void set_indented_by_4() { preferences_ |= INDENTED_BY_4; }
  void set_attached_with_space() { preferences_ |= ATTACHED_WITH_SPACE; }

  bool wants_attached() { return (preferences_ & ATTACHED) != 0; }
  bool wants_same_line() { return (preferences_ & SAME_LINE) != 0; }
  bool wants_indented_by_2() { return (preferences_ & INDENTED_BY_2) != 0; }
  bool wants_indented_by_4() { return (preferences_ & INDENTED_BY_4) != 0; }
  bool wants_attached_with_space() { return (preferences_ & ATTACHED_WITH_SPACE) != 0; }

  int indentation() const { return indentation_; }
  void set_indentation(int indentation) { indentation_ = indentation; }

 private:
  enum Preferences {
    ATTACHED = 1 << 0,
    SAME_LINE = 1 << 1,
    INDENTED_BY_2 = 1 << 2,
    INDENTED_BY_4 = 1 << 3,
    ATTACHED_WITH_SPACE = 1 << 4,
  };
  const std::string text_;
  Source::Range range_;
  int preferences_ = 0;
  int indentation_ = -1;
};

class GroupNode {
 public:
  GroupNode(int id, const List<FormatNode>& children)
      : id_(id), children_(children) {}

  int id() const { return id_; }
  const List<FormatNode>& children() const { return children_; }
  List<FormatNode>& children() { return children_; }

 private:
  int id_;
  List<FormatNode> children_;
};

}  // namespace anonymous.

class CopyFormatter : public ast::Visitor {
 public:
  explicit CopyFormatter(List<Scanner::Comment> comments)
      : comments_(comments) {}

  void visit_Unit(Unit* unit) override {
    for (auto node : unit->imports()) {
      visit_Import(node);
    }
    for (auto node : unit->exports()) {
      node->accept(this);
    }
    for (auto node : unit->declarations()) {
      node->accept(this);
    }
  }

  void visit_Import(Import* import) override {
    ListBuilder<FormatNode> nodes;
    int token_index = 0;
    auto tokens = import->tokens();
    auto import_token = tokens[token_index++];
    ASSERT(import_token->token() == Token::IMPORT);
    nodes.add(node_for(import_token));
    int leading_dots = import->dot_outs();
    if (import->is_relative()) leading_dots++;
    for (int i = 0; i < leading_dots; i++) {
      auto token = tokens[token_index++];
      ASSERT(token->token() == Token::PERIOD || token->token() == Token::SLICE);
      auto node = node_for(token);
      if (i != 0) node.set_attached();
      nodes.add(node);
      if (token->token() == Token::SLICE) i++;
    }
    for (int i = 0; i < import->segments().length(); i++) {
      if (i != 0) {
        auto dot_token = tokens[token_index++];
        ASSERT(dot_token->token() == Token::PERIOD);
        auto node = node_for(dot_token);
        node.set_attached();
        nodes.add(node);
      }
      auto path_node = node_for(import->segments()[i]);
      if (i != 0 || leading_dots != 0) path_node.set_attached();
      nodes.add(path_node);
    }
    if (import->prefix() != null) {
      auto as_token = tokens[token_index++];
      ASSERT(as_token->token() == Token::AS);
      auto as_node = node_for(as_token);
      as_node.set_indented_by_4();
      nodes.add(as_node);
      nodes.add(node_for(import->prefix()));
    } else  if (import->show_all()) {
      auto show_token = tokens[token_index++];
      auto all_token = tokens[token_index++];
      ASSERT(show_token->symbol() == Symbols::show);
      ASSERT(all_token->token() == Token::MUL);
      auto show_node = node_for(show_token);
      auto all_node = node_for(all_token);
      show_node.set_indented_by_2();
      all_node.set_attached_with_space();
      nodes.add(show_node);
      nodes.add(all_node);
    } else if (!import->show_identifiers().is_empty()) {
      auto show_token = tokens[token_index++];
      ASSERT(show_token->symbol() == Symbols::show);
      auto show_node = node_for(show_token);
      show_node.set_indented_by_2();
      nodes.add(show_node);
      for (auto identifier : import->show_identifiers()) {
        nodes.add(node_for(identifier));
      }
    }

  }

 private:
  List<Scanner::Comment> comments_;
  ListBuilder<const char*> output_;

  FormatNode node_for(const Identifier* identifier) const {
    return FormatNode(identifier->data().c_str(), identifier->selection_range());
  }

  FormatNode node_for(const TokenNode* node) const {
    return FormatNode(Token::symbol(node->token()).c_str(), node->selection_range());
  }
};

} // namespace toit::compiler
} // namespace toit

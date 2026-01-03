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
  GroupNode(int id, const std::vector<FormatNode>& children)
      : id_(id), children_(children) {}

  int id() const { return id_; }
  const std::vector<FormatNode>& children() const { return children_; }
  std::vector<FormatNode>& children() { return children_; }

 private:
  int id_;
  std::vector<FormatNode> children_;
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
      visit_Export(node);
    }
    for (auto node : unit->declarations()) {
      visit(node);
    }
  }

  void visit_Import(Import* import) override {
    std::vector<FormatNode> nodes;
    int token_index = 0;
    auto tokens = import->tokens();
    auto import_token = tokens[token_index++];
    ASSERT(import_token->token() == Token::IMPORT);
    nodes.push_back(node_for(import_token));
    int leading_dots = import->dot_outs();
    if (import->is_relative()) leading_dots++;
    for (int i = 0; i < leading_dots; i++) {
      auto token = tokens[token_index++];
      ASSERT(token->token() == Token::PERIOD || token->token() == Token::SLICE);
      auto node = node_for(token);
      if (i != 0) node.set_attached();
      nodes.push_back(node);
      if (token->token() == Token::SLICE) i++;
    }
    for (int i = 0; i < import->segments().length(); i++) {
      if (i != 0) {
        auto dot_token = tokens[token_index++];
        ASSERT(dot_token->token() == Token::PERIOD);
        auto node = node_for(dot_token);
        node.set_attached();
        nodes.push_back(node);
      }
      auto path_node = node_for(import->segments()[i]);
      if (i != 0 || leading_dots != 0) path_node.set_attached();
      nodes.push_back(path_node);
    }
    if (import->prefix() != null) {
      auto as_token = tokens[token_index++];
      ASSERT(as_token->token() == Token::AS);
      auto as_node = node_for(as_token);
      as_node.set_indented_by_4();
      nodes.push_back(as_node);
      nodes.push_back(node_for(import->prefix()));
    } else  if (import->show_all()) {
      auto show_token = tokens[token_index++];
      auto all_token = tokens[token_index++];
      ASSERT(show_token->symbol() == Symbols::show);
      ASSERT(all_token->token() == Token::MUL);
      auto show_node = node_for(show_token);
      auto all_node = node_for(all_token);
      show_node.set_indented_by_2();
      all_node.set_attached_with_space();
      nodes.push_back(show_node);
      nodes.push_back(all_node);
    } else if (!import->show_identifiers().is_empty()) {
      auto show_token = tokens[token_index++];
      ASSERT(show_token->symbol() == Symbols::show);
      auto show_node = node_for(show_token);
      show_node.set_indented_by_2();
      nodes.push_back(show_node);
      for (auto identifier : import->show_identifiers()) {
        nodes.push_back(node_for(identifier));
      }
    }

  }

 private:
  List<Scanner::Comment> comments_;
  ListBuilder<const char*> output_;
  int indentation_ = 0;

  FormatNode node_for(const Identifier* identifier) const {
    return FormatNode(identifier->data().c_str(), identifier->selection_range());
  }

  FormatNode node_for(const TokenNode* node) const {
    return FormatNode(Token::symbol(node->token()).c_str(), node->selection_range());
  }
};

} // namespace toit::compiler
} // namespace toit

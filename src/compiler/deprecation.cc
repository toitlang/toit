// Copyright (C) 2021 Toitware ApS.
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

#include "deprecation.h"

#include "../top.h"

#include "toitdoc_node.h"
#include "ir.h"

namespace toit {
namespace compiler {

using namespace ir;

namespace {  // anonymous.

static std::string trim_whitespace(const std::string& str) {
  auto start = str.find_first_not_of(" \t\n\r\f\v");
  auto end = str.find_last_not_of(" \t\n\r\f\v");

  if (start == std::string::npos) {
    return "";  // String is all whitespace.
  } else {
    return str.substr(start, end - start + 1);
  }
}

class DeprecationFinder : public toitdoc::Visitor {
 public:
  void visit_Contents(toitdoc::Contents* node) {
    for (auto section : node->sections()) {
      if (found_deprecation()) return;
      visit_Section(section);
    }
  }
  void visit_Section(toitdoc::Section* node) {
    for (auto statement : node->statements()) {
      if (found_deprecation()) return;
      statement->accept(this);
    }
  }
  void visit_Statement(toitdoc::Statement* node) { UNREACHABLE(); }

  void visit_CodeSection(toitdoc::CodeSection* node) {}
  // We don't go into lists to find the deprecation warning.
  void visit_Itemized(toitdoc::Itemized* node) {}
  void visit_Item(toitdoc::Item* node) {}

  void visit_Paragraph(toitdoc::Paragraph* node) {
    if (node->expressions().length() == 0) return;
    auto first = node->expressions().first();
    if (!first->is_Text()) return;
    auto text_node = first->as_Text();
    auto text = text_node->text();
    if (strncmp("Deprecated.", text.c_str(), strlen("Deprecated.")) == 0 ||
        strncmp("Deprecated:", text.c_str(), strlen("Deprecated:")) == 0) {
      std::string warning_string = node->to_warning_string();
      // Remove the leading "Deprecated." or "Deprecated:".
      warning_string = warning_string.substr(strlen("Deprecated."));
      warning_string = trim_whitespace(warning_string);
      // Remove a trailing '.' if it exists.
      if (!warning_string.empty() && warning_string.back() == '.') {
        warning_string.pop_back();
      }
      // If the string is not empty, add a '. ' back to the beginning.
      // This way we can attach it to the warning string without any checks.
      if (!warning_string.empty()) {
        warning_string = ". " + warning_string;
      }
      deprecation_message = Symbol::synthetic(warning_string);
    }
  }
  void visit_Expression(toitdoc::Expression* node) { UNREACHABLE(); }
  void visit_Text(toitdoc::Text* node) { UNREACHABLE(); }
  void visit_Code(toitdoc::Code* node) { UNREACHABLE(); }
  void visit_Ref(toitdoc::Ref* node) { UNREACHABLE(); }
  void visit_Link(toitdoc::Link* node) { UNREACHABLE(); }

  Symbol deprecation_message = Symbol::invalid();

 private:
  bool found_deprecation() const {
    return deprecation_message.is_valid();
  }
};

}  // anonymous namespace.

Symbol extract_deprecation_message(const Toitdoc<ir::Node*>& toitdoc) {
  if (!toitdoc.is_valid()) return Symbol::invalid();
  DeprecationFinder finder;
  finder.visit(toitdoc.contents());
  return finder.deprecation_message;
}

} // namespace toit::compiler
} // namespace toit

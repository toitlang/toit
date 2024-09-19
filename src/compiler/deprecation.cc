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

class DeprecationFinder : public toitdoc::Visitor {
 public:
  void visit_Contents(toitdoc::Contents* node) {
    for (auto section : node->sections()) {
      if (found_deprecation) return;
      visit_Section(section);
    }
  }
  void visit_Section(toitdoc::Section* node) {
    for (auto statement : node->statements()) {
      if (found_deprecation) return;
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
      if (strncmp("Deprecated", text.c_str(), strlen("Deprecated")) == 0) {
      found_deprecation = true;
    }
  }
  void visit_Expression(toitdoc::Expression* node) { UNREACHABLE(); }
  void visit_Text(toitdoc::Text* node) { UNREACHABLE(); }
  void visit_Code(toitdoc::Code* node) { UNREACHABLE(); }
  void visit_Ref(toitdoc::Ref* node) { UNREACHABLE(); }
  void visit_Link(toitdoc::Link* node) { UNREACHABLE(); }

  bool found_deprecation = false;
};

}  // anonymous namespace.

bool contains_deprecation_warning(const Toitdoc<ir::Node*>& toitdoc) {
  if (!toitdoc.is_valid()) return false;
  DeprecationFinder finder;
  finder.visit(toitdoc.contents());
  return finder.found_deprecation;
}

} // namespace toit::compiler
} // namespace toit

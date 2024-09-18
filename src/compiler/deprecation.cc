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

  bool found_deprecation = false;
};

class DeprecationCollector : public toitdoc::Visitor {
 public:
  DeprecationCollector(const ToitdocRegistry* registry) : registry_(registry) {}

  void analyze(ir::Node* node) {
    auto toitdoc = registry_->toitdoc_for(node);
    if (!toitdoc.is_valid()) return;
    DeprecationFinder finder;
    finder.visit(toitdoc.contents());
    if (finder.found_deprecation) {
      deprecated_nodes_.insert(node);
    }
  }

  Set<ir::Node*>& deprecated_nodes() {
    return deprecated_nodes_;
  }

 private:
  Set<ir::Node*> deprecated_nodes_;
  const ToitdocRegistry* registry_;
};
}  // anonymous namespace.

Set<ir::Node*> collect_deprecated_elements(Program* program, const ToitdocRegistry* registry) {
  DeprecationCollector collector(registry);
  for (auto cls : program->classes()) {
    collector.analyze(cls);
    for (auto method : cls->methods()) collector.analyze(method);
    for (auto field : cls->fields()) collector.analyze(field);
    // No need to run through the constructors, factories, and statics, as they are
    // also in the program methods.
  }
  for (auto method : program->methods()) collector.analyze(method);
  for (auto global : program->globals()) collector.analyze(global);
  return collector.deprecated_nodes();
}

} // namespace toit::compiler
} // namespace toit

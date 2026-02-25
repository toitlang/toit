// Copyright (C) 2026 Toitware ApS.
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

#include "rename.h"
#include "../ast.h"
#include "../ir.h"
#include "../../utils.h"

namespace toit {
namespace compiler {

void FindReferencesHandler::call_static(ast::Node* node,
                                        ir::Node* resolved1,
                                        ir::Node* resolved2,
                                        List<ir::Node*> candidates,
                                        IterableScope* scope,
                                        ir::Method* surrounding) {
  // Don't overwrite target if already set (e.g., by class_interface_or_mixin
  // when the cursor is on the class part of a static call like Foo.bar).
  if (target_ != null) return;
  ir::Node* t = null;
  if (resolved2 != null) t = resolved2;
  else if (candidates.length() == 1) t = candidates[0];
  else if (resolved1 != null) t = resolved1;
  if (t != null) {
    t = unwrap_reference(t);
    // When the resolved target is an unnamed constructor or factory called
    // by class name (e.g., `MyObj`), the user intends to rename the class,
    // not the constructor. Resolve to the holder class instead.
    if (t->is_Method()) {
      auto* method = t->as_Method();
      if ((method->is_constructor() || method->is_factory()) && method->holder() != null) {
        t = method->holder();
      }
    }
    target_ = t;
  }
}

FindReferencesVisitor::FindReferencesVisitor(ir::Node* target, SourceManager* source_manager, UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map, LspProtocol* protocol)
    : target_(target), source_manager_(source_manager), ir_to_ast_map_(ir_to_ast_map), protocol_(protocol) {}

void FindReferencesVisitor::emit_range(const Source::Range& range) {
  if (!range.is_valid()) return;
  auto from = source_manager_->compute_location(range.from());
  auto to = source_manager_->compute_location(range.to());
  protocol_->find_references()->emit(from.source->absolute_path(),
                                     from.line_number - 1, utf16_offset_in_line(from),
                                     to.line_number - 1, utf16_offset_in_line(to));
}

void FindReferencesVisitor::visit_ReferenceLocal(ir::ReferenceLocal* node) {
  if (node->target() == target_) {
    auto ast_node = ir_to_ast_map_[node];
    if (ast_node != null) emit_range(ast_node->selection_range());
    else emit_range(node->range());
  }
  TraversingVisitor::visit_ReferenceLocal(node);
}

void FindReferencesVisitor::visit_ReferenceGlobal(ir::ReferenceGlobal* node) {
  if (node->target() == target_) {
    auto ast_node = ir_to_ast_map_[node];
    if (ast_node != null) emit_range(ast_node->selection_range());
    else emit_range(node->range());
  }
  TraversingVisitor::visit_ReferenceGlobal(node);
}

void FindReferencesVisitor::visit_ReferenceMethod(ir::ReferenceMethod* node) {
  if (node->target() == target_) {
    auto ast_node = ir_to_ast_map_[node];
    if (ast_node != null) emit_range(ast_node->selection_range());
    else emit_range(node->range());
  }
  TraversingVisitor::visit_ReferenceMethod(node);
}

void FindReferencesVisitor::visit_ReferenceClass(ir::ReferenceClass* node) {
  if (node->target() == target_) {
    auto ast_node = ir_to_ast_map_[node];
    if (ast_node != null) emit_range(ast_node->selection_range());
    else emit_range(node->range());
  }
  TraversingVisitor::visit_ReferenceClass(node);
}

void FindReferencesVisitor::visit_CallVirtual(ir::CallVirtual* node) {
  // TODO(rename): Virtual call sites (e.g., `obj.method`) are not yet matched
  // as references. Virtual dispatch makes it impossible to know at compile time
  // which concrete method is being called without full type-flow analysis.
  // For now, renaming a virtual method only renames the definition and
  // statically-resolved references. Virtual call sites must be renamed manually.
  TraversingVisitor::visit_CallVirtual(node);
}

} // namespace compiler
} // namespace toit

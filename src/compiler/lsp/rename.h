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

#pragma once

#include "selection.h"

namespace toit {
namespace compiler {

/// Unwraps an ir::Reference* node to its underlying definition.
///
/// The resolver callbacks provide resolved nodes that may be wrapped in
/// ir::Reference nodes (ReferenceLocal, ReferenceGlobal, ReferenceMethod,
/// ReferenceClass). This function strips the wrapper to get the actual
/// definition node (Local, Global, Method, Class), which is needed for
/// pointer identity comparisons when searching for references.
static ir::Node* unwrap_reference(ir::Node* node) {
  if (node == null) return null;
  if (node->is_ReferenceMethod()) return node->as_ReferenceMethod()->target();
  if (node->is_ReferenceLocal()) return node->as_ReferenceLocal()->target();
  if (node->is_ReferenceGlobal()) return node->as_ReferenceGlobal()->target();
  if (node->is_ReferenceClass()) return node->as_ReferenceClass()->target();
  return node;
}

/// Returns the name of the given target node as a C string.
///
/// Supports Method, Class, Field, and Local nodes. Returns null for
/// unsupported node types.
inline const char* target_name(ir::Node* target) {
  if (target == null) return null;
  if (target->is_Method()) return target->as_Method()->name().c_str();
  if (target->is_Class()) return target->as_Class()->name().c_str();
  if (target->is_Field()) return target->as_Field()->name().c_str();
  if (target->is_Local()) return target->as_Local()->name().c_str();
  return null;
}

/// Returns the name range of the given target node.
///
/// Supports Method, Class, Field, and Local nodes. Returns an invalid
/// range for unsupported node types.
inline Source::Range target_range(ir::Node* target) {
  if (target == null) return Source::Range::invalid();
  if (target->is_Method()) return target->as_Method()->range();
  if (target->is_Class()) return target->as_Class()->range();
  if (target->is_Field()) return target->as_Field()->range();
  if (target->is_Local()) return target->as_Local()->range();
  return Source::Range::invalid();
}

class FindReferencesHandler : public LspSelectionHandler {
 public:
  FindReferencesHandler(SourceManager* source_manager, LspProtocol* protocol)
      : LspSelectionHandler(protocol), source_manager_(source_manager) {}

  void import_path(const char* path, const char* segment, bool is_first_segment, const char* resolved, const Package& current_package, const PackageLock& package_lock, Filesystem* fs) override {}
  void class_interface_or_mixin(ast::Node* node, IterableScope* scope, ir::Class* holder, ir::Node* resolved, bool needs_interface, bool needs_mixin) override { if (resolved) target_ = unwrap_reference(resolved); }
  void type(ast::Node* node, IterableScope* scope, ResolutionEntry resolved, bool allow_none) override { if (resolved.nodes().length() == 1) target_ = unwrap_reference(resolved.nodes()[0]); }
  void call_virtual(ir::CallVirtual* node, ir::Type type, List<ir::Class*> classes) override {}
  void call_prefixed(ast::Dot* node, ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates, IterableScope* scope) override { call_static(node, resolved1, resolved2, candidates, scope, null); }
  void call_class(ast::Dot* node, ir::Class* klass, ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates, IterableScope* scope) override { call_static(node, resolved1, resolved2, candidates, scope, null); }

  void call_static(ast::Node* node, ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates, IterableScope* scope, ir::Method* surrounding) override;

  void call_block(ast::Dot* node, ir::Node* ir_receiver) override {}
  void call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) override {}
  void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name, int module, int primitive, bool on_module) override {}
  void field_storing_parameter(ast::Parameter* node, List<ir::Field*> fields, bool field_storing_is_allowed) override {}
  void this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding) override {}

  void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) override { if (entry.nodes().length() == 1) target_ = unwrap_reference(entry.nodes()[0]); }
  void expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) override { if (entry.nodes().length() == 1) target_ = unwrap_reference(entry.nodes()[0]); }

  void return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) override {}
  void toitdoc_ref(ast::Node* node, List<ir::Node*> candidates, ToitdocScopeIterator* iterator, bool is_signature_toitdoc) override {}

  ir::Node* target() const { return target_; }
  SourceManager* source_manager() const { return source_manager_; }

 private:
  SourceManager* source_manager_;
  ir::Node* target_ = null;
};

class FindReferencesVisitor : public ir::TraversingVisitor {
 public:
  FindReferencesVisitor(ir::Node* target, SourceManager* source_manager, UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map, LspProtocol* protocol);

  void visit_ReferenceLocal(ir::ReferenceLocal* node) override;
  void visit_ReferenceGlobal(ir::ReferenceGlobal* node) override;
  void visit_ReferenceMethod(ir::ReferenceMethod* node) override;
  void visit_ReferenceClass(ir::ReferenceClass* node) override;
  void visit_CallVirtual(ir::CallVirtual* node) override;

 private:
  void emit_range(const Source::Range& range);

  ir::Node* target_;
  SourceManager* source_manager_;
  UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map_;
  LspProtocol* protocol_;
};

} // namespace compiler
} // namespace toit

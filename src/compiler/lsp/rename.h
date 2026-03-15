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

#include "../set.h"
#include "../token.h"
#include "../package.h"

namespace toit {
namespace compiler {

/// Unwraps an ir::Reference* node to its underlying definition.
///
/// The resolver callbacks provide resolved nodes that may be wrapped in
/// ir::Reference nodes (ReferenceLocal, ReferenceGlobal, ReferenceMethod,
/// ReferenceClass). This function strips the wrapper to get the actual
/// definition node (Local, Global, Method, Class), which is needed for
/// pointer identity comparisons when searching for references.
inline ir::Node* unwrap_reference(ir::Node* node) {
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

/// Returns whether the given target node is defined in the SDK.
///
/// SDK symbols cannot be renamed because their source files are not
/// user-editable. Both prepareRename and rename should refuse to operate
/// on SDK targets.
///
/// Locals and parameters are never from the SDK (they live inside method
/// bodies that are being compiled from user code, even if the method type
/// comes from the SDK).
inline bool is_sdk_target(ir::Node* target, SourceManager* source_manager) {
  Source::Range range = target_range(target);
  if (!range.is_valid()) return false;
  auto* source = source_manager->source_for_position(range.from());
  if (source == null) return false;
  return source->package_id() == Package::SDK_PACKAGE_ID;
}

class FindReferencesHandler : public LspSelectionHandler {
 public:
  FindReferencesHandler(SourceManager* source_manager, LspProtocol* protocol)
      : LspSelectionHandler(protocol), source_manager_(source_manager) {}

  void import_path(const char* path, const char* segment, bool is_first_segment, const char* resolved, const Package& current_package, const PackageLock& package_lock, Filesystem* fs) override {}
  void class_interface_or_mixin(ast::Node* node, IterableScope* scope, ir::Class* holder, ir::Node* resolved, bool needs_interface, bool needs_mixin) override { if (resolved) target_ = unwrap_reference(resolved); }
  void type(ast::Node* node, IterableScope* scope, ResolutionEntry resolved, bool allow_none) override { if (resolved.nodes().length() == 1) target_ = unwrap_reference(resolved.nodes()[0]); }
  void call_virtual(ir::CallVirtual* node, ir::Type type, List<ir::Class*> classes) override {
    // Try to find a method that matches the virtual call selector.
    Symbol selector = node->selector();
    if (type.is_class()) {
      auto klass = type.klass();
      while (klass != null) {
        for (auto method : klass->methods()) {
          if (method->name() == selector &&
              method->resolution_shape().accepts(node->shape())) {
            target_ = method;
            return;
          }
        }
        klass = klass->super();
      }
    }
    // Fall back: search all classes for a matching method.
    for (auto klass : classes) {
      for (auto method : klass->methods()) {
        if (method->name() == selector &&
            method->resolution_shape().accepts(node->shape())) {
          target_ = method;
          return;
        }
      }
    }
  }
  void call_prefixed(ast::Dot* node, ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates, IterableScope* scope) override { call_static(node, resolved1, resolved2, candidates, scope, null); }
  void call_class(ast::Dot* node, ir::Class* klass, ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates, IterableScope* scope) override { call_static(node, resolved1, resolved2, candidates, scope, null); }

  void call_static(ast::Node* node, ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates, IterableScope* scope, ir::Method* surrounding) override;

  void call_block(ast::Dot* node, ir::Node* ir_receiver) override {}
  void call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) override {
    if (ir_call_target == null || ir_call_target->is_Error()) return;
    if (!ir_call_target->is_ReferenceMethod()) return;

    auto name = name_node->as_LspSelection()->data();
    auto* ir_method = ir_call_target->as_ReferenceMethod()->target();

    // Try matching against the method's parameter list (available for
    // same-module methods that have already been resolved).
    for (auto parameter : ir_method->parameters()) {
      if (parameter->name() == name) {
        target_ = parameter;
        return;
      }
    }

    // For cross-module methods the parameter list may not yet be populated
    // at resolution time.  Fall back to checking the resolution shape which
    // is always available.
    auto shape = ir_method->resolution_shape();
    for (int i = 0; i < shape.names().length(); i++) {
      if (shape.names()[i] == name) {
        // We don't have an ir::Parameter node for this cross-module
        // parameter.  Create a temporary Local that carries the correct
        // name and the call-site range so that emit_prepare_rename can
        // produce a valid response.
        auto range = name_node->as_LspSelection()->selection_range();
        target_ = _new ir::Local(name, true, false, range);
        return;
      }
    }
  }
  void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name, int module, int primitive, bool on_module) override {}
  void field_storing_parameter(ast::Parameter* node, List<ir::Field*> fields, bool field_storing_is_allowed) override {
    if (node->name()->is_LspSelection()) {
      auto name = node->name()->data();
      for (auto field : fields) {
        if (field->name() == name) {
          target_ = field;
          return;
        }
      }
    }
  }
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

/// Determines whether a CallVirtual node should be included in rename results.
///
/// Virtual calls in the IR don't carry a resolved method target — only a
/// selector name and a call shape. Without full type-flow analysis, we cannot
/// know with certainty which concrete method a virtual call dispatches to.
///
/// This filter uses several layers of analysis to decide whether a virtual
/// call whose selector and shape match the target method should be included:
///
/// 1. **Operator exclusion**: Operators (like +, [], etc.) cannot be
///    meaningfully renamed, so they are always excluded.
///
/// 2. **Class hierarchy computation**: We compute the set of all classes
///    that participate in the target method's dispatch chain — the holder
///    class, all ancestors that define the same method, all descendants
///    (which inherit or override it), and all interfaces/mixins that
///    declare it.
///
/// 3. **Ambiguity detection**: If other, unrelated class hierarchies also
///    define a method with the same name and compatible shape, the match
///    is "ambiguous" — a virtual call with that selector could be
///    dispatching to either hierarchy. For ambiguous methods, we apply
///    package-based filtering to reduce false positives.
///
/// 4. **SDK exclusion**: SDK methods cannot be renamed (their source
///    files are not user-editable), so the filter is inactive for SDK
///    targets.
///
/// 5. **Package-based filtering** (ambiguous names only): When the name
///    is ambiguous, a virtual call site is included only if:
///    - It is in the same source file as the target method, or
///    - It is in the same package as the target method.
///    This heuristic approximates visibility: call sites in the same
///    package are likely referencing the same class hierarchy.
class VirtualCallFilter {
 public:
  /// Builds a filter for the given target and program.
  ///
  /// If the target is not an instance method, or if it is an operator,
  /// the returned filter is inactive and `should_include` always returns
  /// false.
  static VirtualCallFilter build(ir::Node* target,
                                 ir::Program* program,
                                 SourceManager* source_manager);

  /// Returns true if the given CallVirtual node should be included in
  /// rename results.
  bool should_include(ir::CallVirtual* node) const;

  /// Returns true if this filter is active (the target is a renameable
  /// instance method with a non-operator name).
  bool is_active() const { return method_ != null; }

 private:
  VirtualCallFilter()
      : method_(null)
      , is_ambiguous_(false)
      , target_source_path_(null)
      , source_manager_(null) {}

  /// Computes the set of classes participating in the target method's
  /// dispatch.
  ///
  /// A class "participates" if it defines or inherits the target method
  /// and is connected to the holder through the class hierarchy (super
  /// classes, sub classes, interfaces, or mixins).
  void compute_participating_classes(ir::Program* program);

  /// Determines whether the target method's name+shape is ambiguous.
  ///
  /// We consider the method ambiguous if there exists at least one class
  /// outside the participating set that defines a method with the same
  /// name and a compatible shape. Such a class belongs to an unrelated
  /// hierarchy, and a virtual call with the matching selector could
  /// dispatch to either hierarchy.
  void detect_ambiguity(ir::Program* program);

  ir::Method* method_;
  UnorderedSet<ir::Class*> participating_classes_;
  bool is_ambiguous_;
  std::string target_package_id_;
  const char* target_source_path_;
  SourceManager* source_manager_;
};

class FindReferencesVisitor : public ir::TraversingVisitor {
 public:
  FindReferencesVisitor(ir::Node* target,
                        SourceManager* source_manager,
                        UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                        LspProtocol* protocol,
                        const VirtualCallFilter& virtual_call_filter);

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
  const VirtualCallFilter& virtual_call_filter_;
};

} // namespace compiler
} // namespace toit

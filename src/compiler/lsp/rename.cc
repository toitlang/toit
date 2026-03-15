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
#include "../token.h"
#include "../sources.h"
#include "../package.h"
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
    // Named constructors (e.g., `constructor.deserialize`) should NOT be
    // redirected — the user wants to rename the constructor's own name.
    if (t->is_Method()) {
      auto* method = t->as_Method();
      if ((method->is_constructor() || method->is_factory()) && method->holder() != null) {
        auto holder_name = method->holder()->name();
        if (method->name() == holder_name || method->name() == Symbols::constructor) {
          t = method->holder();
        }
      }
    }
    target_ = t;
  }
}

// ---------------------------------------------------------------------------
// VirtualCallFilter
// ---------------------------------------------------------------------------

/// Returns the package ID of the source file containing the given IR node.
/// Falls back to the entry package ID if the source cannot be determined.
static std::string package_id_for_range(const Source::Range& range,
                                        SourceManager* source_manager) {
  if (!range.is_valid()) return Package::ENTRY_PACKAGE_ID;
  auto* source = source_manager->source_for_position(range.from());
  if (source == null) return Package::ENTRY_PACKAGE_ID;
  return source->package_id();
}

/// Returns the absolute path of the source file containing the given IR range.
/// Returns null if the source cannot be determined.
static const char* source_path_for_range(const Source::Range& range,
                                         SourceManager* source_manager) {
  if (!range.is_valid()) return null;
  auto* source = source_manager->source_for_position(range.from());
  if (source == null) return null;
  return source->absolute_path();
}

/// Returns whether a class defines an instance method with the given name
/// and a shape that accepts the given call shape.
static bool class_has_matching_method(ir::Class* klass,
                                      Symbol name,
                                      const CallShape& shape) {
  for (auto method : klass->methods()) {
    if (method->name() == name &&
        method->resolution_shape().accepts(shape)) {
      return true;
    }
  }
  return false;
}

VirtualCallFilter VirtualCallFilter::build(ir::Node* target,
                                           ir::Program* program,
                                           SourceManager* source_manager) {
  VirtualCallFilter filter;
  filter.source_manager_ = source_manager;

  // Only active for instance methods with a holder class.
  if (target == null || !target->is_Method()) return filter;
  auto* method = target->as_Method();
  if (method->holder() == null) return filter;
  if (!method->is_instance()) return filter;

  // Operators cannot be meaningfully renamed.
  if (is_operator_name(method->name())) return filter;

  // SDK methods cannot be renamed — their source files are not
  // user-editable. Don't match virtual call sites for them.
  if (is_sdk_target(target, source_manager)) return filter;

  filter.method_ = method;

  // Determine the target method's source location metadata.
  auto holder_range = method->holder()->range();
  filter.target_package_id_ = package_id_for_range(holder_range, source_manager);
  filter.target_source_path_ = source_path_for_range(holder_range, source_manager);

  filter.compute_participating_classes(program);
  filter.detect_ambiguity(program);

  return filter;
}

void VirtualCallFilter::compute_participating_classes(ir::Program* program) {
  auto* holder = method_->holder();
  Symbol name = method_->name();
  // Build the call shape from the method's resolution shape so we can
  // test compatibility with other methods' resolution shapes via `accepts`.
  auto method_shape = method_->resolution_shape().to_plain_shape().to_equivalent_call_shape();

  // Phase 1: Walk up from the holder through supers.
  // Add each ancestor that defines a method with the same name and
  // compatible shape.
  for (auto* klass = holder; klass != null; klass = klass->super()) {
    if (class_has_matching_method(klass, name, method_shape)) {
      participating_classes_.insert(klass);
    }
  }

  // Phase 2: Add interfaces and mixins that declare the matching method.
  // Interfaces and mixins form a separate axis of the type hierarchy.
  // A class that implements an interface inherits the interface's contract,
  // so virtual calls typed as the interface should also be included.
  for (auto* klass : program->classes()) {
    if (klass->is_interface() || klass->is_mixin()) {
      if (class_has_matching_method(klass, name, method_shape)) {
        // Check whether this interface/mixin is connected to our holder:
        // either the holder implements it, or one of the participating
        // classes does.
        bool is_connected = false;

        // Check if any participating class lists this interface/mixin.
        for (auto* participant : participating_classes_.underlying_set()) {
          for (auto iface : participant->interfaces()) {
            if (iface == klass) { is_connected = true; break; }
          }
          if (is_connected) break;
          for (auto mixin : participant->mixins()) {
            if (mixin == klass) { is_connected = true; break; }
          }
          if (is_connected) break;
        }

        if (is_connected) {
          participating_classes_.insert(klass);
        }
      }
    }
  }

  // Phase 3: Walk all classes and add descendants of any participating class.
  // A descendant inherits the method definition even if it doesn't override
  // it, so virtual calls on descendants should also match.
  //
  // We iterate until no new classes are added (fixed-point), because
  // adding a descendant may cause its own descendants to become reachable.
  bool changed = true;
  while (changed) {
    changed = false;
    for (auto* klass : program->classes()) {
      if (participating_classes_.contains(klass)) continue;
      // Check if any of klass's supers or interfaces/mixins are participating.
      if (klass->has_super() && participating_classes_.contains(klass->super())) {
        participating_classes_.insert(klass);
        changed = true;
        continue;
      }
      for (auto iface : klass->interfaces()) {
        if (participating_classes_.contains(iface)) {
          participating_classes_.insert(klass);
          changed = true;
          break;
        }
      }
      if (participating_classes_.contains(klass)) continue;
      for (auto mixin : klass->mixins()) {
        if (participating_classes_.contains(mixin)) {
          participating_classes_.insert(klass);
          changed = true;
          break;
        }
      }
    }
  }
}

void VirtualCallFilter::detect_ambiguity(ir::Program* program) {
  Symbol name = method_->name();
  auto method_shape = method_->resolution_shape().to_plain_shape()
                          .to_equivalent_call_shape();

  for (auto* klass : program->classes()) {
    // Skip classes that are part of our dispatch hierarchy.
    if (participating_classes_.contains(klass)) continue;

    if (class_has_matching_method(klass, name, method_shape)) {
      is_ambiguous_ = true;
      return;
    }
  }

  is_ambiguous_ = false;
}

bool VirtualCallFilter::should_include(ir::CallVirtual* node) const {
  if (method_ == null) return false;

  if (node->selector() != method_->name()) return false;
  if (!method_->resolution_shape().accepts(node->shape())) return false;

  // Name and shape match. If the method is unambiguous across the entire
  // program, every matching virtual call must dispatch to our hierarchy.
  if (!is_ambiguous_) return true;

  // Ambiguous case: apply package-based proximity filtering.
  // Determine the call site's source location.
  auto* call_source = source_manager_->source_for_position(node->range().from());
  if (call_source == null) return false;

  // Same source file: highest confidence — the call is almost certainly
  // referencing the local hierarchy.
  if (target_source_path_ != null &&
      strcmp(call_source->absolute_path(), target_source_path_) == 0) {
    return true;
  }

  // Same package: the call site is in the same library/package as the
  // target method's holder class, so it likely refers to the same hierarchy.
  if (call_source->package_id() == target_package_id_) return true;

  // Different package with an ambiguous name: skip to avoid false positives.
  return false;
}

// ---------------------------------------------------------------------------
// FindReferencesVisitor
// ---------------------------------------------------------------------------

FindReferencesVisitor::FindReferencesVisitor(ir::Node* target,
                                             SourceManager* source_manager,
                                             UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                                             LspProtocol* protocol,
                                             const VirtualCallFilter& virtual_call_filter)
    : target_(target)
    , source_manager_(source_manager)
    , ir_to_ast_map_(ir_to_ast_map)
    , protocol_(protocol)
    , virtual_call_filter_(virtual_call_filter) {}

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
  if (virtual_call_filter_.should_include(node)) {
    // CallVirtual::range() contains the selector's source range (e.g.,
    // the range of "bar" in "foo.bar"), which is exactly what we want
    // to rename.
    emit_range(node->range());
  }
  TraversingVisitor::visit_CallVirtual(node);
}

} // namespace compiler
} // namespace toit

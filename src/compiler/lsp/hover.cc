// Copyright (C) 2026 Toit contributors.
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

#include "hover.h"

#include "../resolution.h"
#include "../sources.h"

namespace toit {
namespace compiler {

void HoverHandler::import_path(const char* path,
                               const char* segment,
                               bool is_first_segment,
                               const char* resolved,
                               const Package& package,
                               const PackageLock& package_lock,
                               Filesystem* filesystem) {
  // No hover for import paths.
  // The import_path callback fires during import resolution, before all
  // files are loaded. Emitting here would disrupt the file-server protocol.
  // TODO: Could be handled by a delayed callback, similar to the renaming.
}

void HoverHandler::class_interface_or_mixin(ast::Node* node,
                                            IterableScope* scope,
                                            resolution::ClassView holder,
                                            resolution::NodeView resolved,
                                            bool needs_interface,
                                            bool needs_mixin) {
  emit_hover(resolved, null);
}

void HoverHandler::type(ast::Node* node,
                        IterableScope* scope,
                        ResolutionEntry entry,
                        bool allow_none) {
  if (entry.is_class()) {
    emit_hover(entry.klass(), entry.klass()->name().c_str());
  }
}

void HoverHandler::call_virtual(resolution::CallVirtualView node,
                                resolution::Type type,
                                List<resolution::ClassView> classes) {
  Symbol selector = node->selector();

  if (type.is_none()) return;

  if (type.is_class()) {
    walk_class_hierarchy(type.klass(), classes, [&](resolution::ClassView current) -> bool {
      for (resolution::MethodInstanceView method : current->methods()) {
        if (method->name() == selector && method->resolution_shape().accepts(node->shape())) {
          emit_hover(method, null);
          return true;
        }
      }
      return false;
    });
  }
  // When the type is 'any', we intentionally don't search all classes.
  // Picking an arbitrary match could show the wrong hover info.
}

void HoverHandler::call_prefixed(ast::Dot* node,
                                 resolution::NodeView resolved1,
                                 resolution::NodeView resolved2,
                                 List<resolution::NodeView> candidates,
                                 IterableScope* scope) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  }
}

void HoverHandler::call_class(ast::Dot* node,
                              resolution::ClassView klass,
                              resolution::NodeView resolved1,
                              resolution::NodeView resolved2,
                              List<resolution::NodeView> candidates,
                              IterableScope* scope) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  } else {
    emit_hover(klass, null);
  }
}

void HoverHandler::call_static(ast::Node* node,
                               resolution::NodeView resolved1,
                               resolution::NodeView resolved2,
                               List<resolution::NodeView> candidates,
                               IterableScope* scope,
                               resolution::MethodView surrounding) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  }
}

void HoverHandler::call_block(ast::Dot* node, resolution::NodeView ir_receiver) {
  // No hover for blocks yet.
}

void HoverHandler::call_static_named(ast::Node* name_node, resolution::NodeView ir_call_target, List<resolution::NodeView> candidates) {
  if (ir_call_target != null) {
    emit_hover(ir_call_target, null);
  }
}

void HoverHandler::call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                                  int module, int primitive, bool on_module) {
  // No hover for primitives.
}

void HoverHandler::field_storing_parameter(ast::Parameter* node,
                                           List<resolution::FieldView> fields,
                                           bool field_storing_is_allowed) {
  if (fields.length() == 1) {
    emit_hover(fields.first(), null);
  }
}

void HoverHandler::this_(ast::Identifier* node, resolution::ClassView enclosing_class, IterableScope* scope, resolution::MethodView surrounding) {
  emit_hover(enclosing_class, null);
}

void HoverHandler::emit_hover_for_entry(ResolutionEntry entry) {
  if (entry.kind() == ResolutionEntry::NODES) {
    if (entry.nodes().length() >= 1) {
      emit_hover(entry.nodes().first(), null);
    }
  } else if (entry.is_class()) {
    emit_hover(entry.klass(), null);
  }
}

void HoverHandler::show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  emit_hover_for_entry(entry);
}

void HoverHandler::expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  emit_hover_for_entry(entry);
}

void HoverHandler::return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) {
  // No hover for labels.
}

void HoverHandler::toitdoc_ref(ast::Node* ref,
                               List<resolution::NodeView> candidates,
                               ToitdocScopeIterator* iterator,
                               bool is_signature) {
  if (candidates.length() != 1) return;
  emit_hover(candidates.first(), null);
}

void HoverHandler::emit_hover(resolution::NodeView node, const char* name) {
  if (node == null) return;

  if (node->is_Reference()) {
    node = node->as_Reference()->target();
  }

  // We only care about emitting hover coordinates if the node is something 
  // that exists in the Toit summary (Method, Class, Field, Global).
  Source::Range node_range = Source::Range::invalid();
  if (node->is_Method()) node_range = node->as_Method()->range();
  else if (node->is_Class()) node_range = node->as_Class()->range();
  else if (node->is_Field()) node_range = node->as_Field()->range();
  else if (node->is_Global()) node_range = node->as_Global()->range();

  // Constructors may have an invalid range (e.g., synthetic constructors).
  // In that case, fall back to the enclosing class's range.
  if (!node_range.is_valid() && node->is_Constructor()) {
    node_range = node->as_Constructor()->klass()->range();
  }

  if (!node_range.is_valid()) {
    if (deferred_node_ == null) {
      deferred_node_ = node;
    }
    return;
  }

  Source::Location location = source_manager_->compute_location(node_range.from());
  if (location.source == null) return;

  int start = location.source->offset_in_source(node_range.from());
  int end = location.source->offset_in_source(node_range.to());

  protocol()->hover()->emit_toitdoc_ref(location.source->absolute_path(), start, end);
  exit(0);
}

void HoverHandler::finalize() {
  if (deferred_node_ == null) return;
  emit_hover(deferred_node_, null);
}

} // namespace toit::compiler
} // namespace toit


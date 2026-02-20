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

#include "hover.h"

#include "../ir.h"
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
  if (resolved == null) return;
  std::string message = "Import: ";
  message += resolved;
  protocol()->hover()->emit(message.c_str());
}

void HoverHandler::class_interface_or_mixin(ast::Node* node,
                                            IterableScope* scope,
                                            ir::Class* holder,
                                            ir::Node* resolved,
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

void HoverHandler::call_virtual(ir::CallVirtual* node,
                                ir::Type type,
                                List<ir::Class*> classes) {
  Symbol selector = node->selector();
  
  if (type.is_none()) return;

  if (type.is_class()) {
    ir::Class* klass = type.klass();
    while (klass != null) {
      for (int i = -1; i < klass->mixins().length(); i++) {
        auto current = i == -1 ? klass : klass->mixins()[i];
        for (ir::MethodInstance* method : current->methods()) {
          if (method->name() == selector && method->resolution_shape().accepts(node->shape())) {
            emit_hover(method, null);
            return;
          }
        }
      }
      if (klass->super() == null && (klass->is_interface() || klass->is_mixin())) {
        klass = classes.length() > 0 ? classes[0] : null; // Usually Object
      } else {
        klass = klass->super();
      }
    }
  } else if (type.is_any()) {
    for (int i = 0; i < classes.length(); i++) {
      ir::Class* klass = classes[i];
      for (ir::MethodInstance* method : klass->methods()) {
        if (method->name() == selector && method->resolution_shape().accepts(node->shape())) {
          emit_hover(method, null);
          return;
        }
      }
    }
  }
}

void HoverHandler::call_prefixed(ast::Dot* node,
                                 ir::Node* resolved1,
                                 ir::Node* resolved2,
                                 List<ir::Node*> candidates,
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
                              ir::Class* klass,
                              ir::Node* resolved1,
                              ir::Node* resolved2,
                              List<ir::Node*> candidates,
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
                               ir::Node* resolved1,
                               ir::Node* resolved2,
                               List<ir::Node*> candidates,
                               IterableScope* scope,
                               ir::Method* surrounding) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  }
}

void HoverHandler::call_block(ast::Dot* node, ir::Node* ir_receiver) {
  // No hover for blocks yet.
}

void HoverHandler::call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) {
  if (ir_call_target != null) {
    emit_hover(ir_call_target, null);
  }
}

void HoverHandler::call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                                  int module, int primitive, bool on_module) {
  // No hover for primitives.
}

void HoverHandler::field_storing_parameter(ast::Parameter* node,
                                           List<ir::Field*> fields,
                                           bool field_storing_is_allowed) {
  if (fields.length() == 1) {
    emit_hover(fields.first(), null);
  }
}

void HoverHandler::this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding) {
  emit_hover(enclosing_class, null);
}

void HoverHandler::show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  if (entry.kind() == ResolutionEntry::NODES) {
    if (entry.nodes().length() >= 1) {
      emit_hover(entry.nodes().first(), null);
    }
  } else if (entry.is_class()) {
    emit_hover(entry.klass(), null);
  }
}

void HoverHandler::expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  if (entry.kind() == ResolutionEntry::NODES) {
    if (entry.nodes().length() >= 1) {
      emit_hover(entry.nodes().first(), null);
    }
  } else if (entry.is_class()) {
    emit_hover(entry.klass(), null);
  }
}

void HoverHandler::return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) {
  // No hover for labels.
}

void HoverHandler::toitdoc_ref(ast::Node* ref,
                               List<ir::Node*> candidates,
                               ToitdocScopeIterator* iterator,
                               bool is_signature) {
  if (candidates.length() != 1) return;
  emit_hover(candidates.first(), null);
}

void HoverHandler::emit_hover(ir::Node* node, const char* name) {
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

  // If node is a constructor (usually generated synthetic methods don't have good Toitdocs),
  // we could optionally point to the class itself if we wanted. But the summary actually
  // keeps constructors and classes separate, so returning the constructor's node_range is fine.
  if (!node_range.is_valid() && node->is_Constructor()) {
    node_range = node->as_Constructor()->klass()->range();
  }

  if (!node_range.is_valid()) {
    if (!has_emitted_ && deferred_node_ == null) {
      deferred_node_ = node;
    }
    return;
  }

  Source* source = source_manager_->source_for_position(node_range.from());
  if (source == null) return;

  int start = source->offset_in_source(node_range.from());
  int end = source->offset_in_source(node_range.to());

  std::string response = 
      std::string(source->absolute_path()) + "\n" +
      std::to_string(start) + "\n" +
      std::to_string(end) + "\n";

  protocol()->hover()->emit(response.c_str());
  has_emitted_ = true;
}

void HoverHandler::finalize() {
  if (has_emitted_ || deferred_node_ == null) return;
  emit_hover(deferred_node_, null);
}

} // namespace compiler
} // namespace toit


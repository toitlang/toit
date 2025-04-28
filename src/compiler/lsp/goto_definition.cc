// Copyright (C) 2019 Toitware ApS.
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

#include "goto_definition.h"

#include "../resolver_scope.h"

namespace toit {
namespace compiler {

void GotoDefinitionHandler::terminate() {
  exit(0);
}

void GotoDefinitionHandler::_print_range(Source::Range range) {
  if (printed_definitions_.contains(range)) return;
  printed_definitions_.insert(range);
  protocol()->goto_definition()->emit(range_to_lsp_location(range, source_manager_));
}

void GotoDefinitionHandler::_print_range(ir::Node* resolved) {
  if (resolved == null || resolved->is_Error()) return;
  if (resolved->is_ReferenceMethod()) {
    _print_range(resolved->as_ReferenceMethod()->target()->range());
  } else if (resolved->is_ReferenceLocal()) {
    _print_range(resolved->as_ReferenceLocal()->target()->range());
  } else if (resolved->is_ReferenceGlobal()) {
    _print_range(resolved->as_ReferenceGlobal()->target()->range());
  } else if (resolved->is_ReferenceClass()) {
    _print_range(resolved->as_ReferenceClass()->target()->range());
  } else if (resolved->is_Method()) {
    _print_range(resolved->as_Method()->range());
  } else if (resolved->is_Local()) {
    _print_range(resolved->as_Local()->range());
  } else if (resolved->is_Class()) {
    _print_range(resolved->as_Class()->range());
  } else if (resolved->is_Field()) {
    _print_range(resolved->as_Field()->range());
  }
}

void GotoDefinitionHandler::_print_all(ResolutionEntry entry) {
  if (entry.is_prefix()) return;
  _print_all(entry.nodes());
}

void GotoDefinitionHandler::_print_all(List<ir::Node*> nodes) {
  for (auto resolved_node : nodes) {
    _print_range(resolved_node);
  }
}

void GotoDefinitionHandler::class_interface_or_mixin(ast::Node* node,
                                                     IterableScope* scope,
                                                     ir::Class* holder,
                                                     ir::Node* resolved,
                                                     bool needs_interface,
                                                     bool needs_mixin) {
  if (resolved != null && resolved->is_Class()) {
    _print_range(resolved);
  }
  terminate();
}

void GotoDefinitionHandler::type(ast::Node* node,
                                 IterableScope* scope,
                                 ResolutionEntry resolved,
                                 bool allow_none) {
  // We are ok with resolving to many nodes (even ambiguous ones).
  // This will help the user to figure out why they have an error.
  _print_all(resolved);
  terminate();
}

void GotoDefinitionHandler::call_virtual(ir::CallVirtual* node,
                                         ir::Type type,
                                         List<ir::Class*> classes) {
  Symbol selector = node->selector();
  auto lsp_selection_dot = node->target()->as_LspSelectionDot();
  bool is_for_named = lsp_selection_dot->is_for_named();
  Symbol name = lsp_selection_dot->name();

  if (type.is_none()) {
    // We don't terminate() here, as there might be multiple definitions that need to
    //   get resolved. This happens when a getter and setter are both target of a
    //   compound assignment.
    return;
  }
  if (type.is_any()) {
    for (auto klass : classes) {
      for (auto method : klass->methods()) {
        if (method->name() == selector &&
            method->resolution_shape().accepts(node->shape())) {
          if (is_for_named) {
            for (auto parameter : method->parameters()) {
              if (parameter->name() == name) {
                _print_range(parameter->range());
                break;
              }
            }
          } else {
            _print_range(method->range());
          }
        }
      }
    }
    return;
  }
  ASSERT(type.is_class());
  auto klass = type.klass();

  // Keep track of the possible candidates, in case we don't find a full match.
  Map<ResolutionShape, ir::Method*> candidates;
  while (klass != null) {
    for (int i = -1; i < klass->mixins().length(); i++) {
      auto current = i == -1
          ? klass
          : klass->mixins()[i];
      for (auto method : current->methods()) {
        if (method->name() != selector) continue;
        if (method->resolution_shape().accepts(node->shape())) {
          if (is_for_named) {
            auto name = lsp_selection_dot->name();
            for (auto parameter : method->parameters()) {
              if (parameter->name() == name) {
                _print_range(parameter->range());
                break;
              }
            }
          } else {
            _print_range(method->range());
          }
          return;
        }
        // Only add new candidates, if they aren't shadowed.
        // TODO(florian): different resolution shapes could still shadow each other.
        if (candidates.find(method->resolution_shape()) != candidates.end()) continue;
        candidates[method->resolution_shape()] = method;
      }
    }
    if (klass->super() == null &&
        (klass->is_interface() || klass->is_mixin())) {
      // Add the Object methods, which every object has.
      klass = classes[0];
    } else {
      klass = klass->super();
    }
  }

  // Apparently we didn't find a full match. Propose the candidates instead.
  for (auto shape : candidates.keys()) {
    _print_range(candidates[shape]->range());
  }
}

void GotoDefinitionHandler::call_statically_resolved(ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates) {
  bool had_resolved_node = false;
  if (resolved1 != null && !resolved1->is_Error()) {
    _print_range(resolved1);
    had_resolved_node = true;
  }
  if (resolved2 != null && !resolved2->is_Error()) {
    _print_range(resolved2);
    had_resolved_node = true;
  }
  if (had_resolved_node) return;

  // Otherwise try to give some help by listing all possibilities.
  for (auto candidate : candidates) {
    if (candidate->is_Method()) {
      _print_range(candidate->as_Method()->range());
    }
  }
}

void GotoDefinitionHandler::call_prefixed(ast::Dot* node,
                                          ir::Node* resolved1,
                                          ir::Node* resolved2,
                                          List<ir::Node*> candidates,
                                          IterableScope* scope) {
  call_statically_resolved(resolved1, resolved2, candidates);
  terminate();
}

void GotoDefinitionHandler::call_class(ast::Dot* node,
                                       ir::Class* klass,
                                       ir::Node* resolved1,
                                       ir::Node* resolved2,
                                       List<ir::Node*> candidates,
                                       IterableScope* scope) {
  call_statically_resolved(resolved1, resolved2, candidates);
  if ((resolved1 == null || resolved1->is_Error()) &&
      (resolved2 == null || resolved2->is_Error())) {
    // If we didn't find an exact match, also give the virtual goto-definition a chance
    // to propose candidates.
    return;
  }
  terminate();
}

void GotoDefinitionHandler::call_static(ast::Node* node,
                                        ir::Node* resolved1,
                                        ir::Node* resolved2,
                                        List<ir::Node*> candidates,
                                        IterableScope* scope,
                                        ir::Method* surrounding) {
  call_statically_resolved(resolved1, resolved2, candidates);
  terminate();
}

void GotoDefinitionHandler::call_block(ast::Dot* node, ir::Node* ir_receiver) {
  terminate();
}

void GotoDefinitionHandler::call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) {
  if (ir_call_target == null || ir_call_target->is_Error()) terminate();
  if (!ir_call_target->is_ReferenceMethod()) exit(1);
  auto name = name_node->as_LspSelection()->data();
  auto ir_method = ir_call_target->as_ReferenceMethod()->target();
  for (auto parameter : ir_method->parameters()) {
    if (parameter->name() == name) {
      _print_range(parameter->range());
      terminate();
    }
  }
  terminate();
}

void GotoDefinitionHandler::call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                                           int module, int primitive, bool on_module) {
  // Nothing to go to.
  terminate();
}

void GotoDefinitionHandler::field_storing_parameter(ast::Parameter* node,
                                                    List<ir::Field*> fields,
                                                    bool field_storing_is_allowed) {
  // We will go to definition, even if field-storing parameters aren't allowed.
  auto name = node->name()->data();
  for (auto field : fields) {
    if (field->name() == name) {
      _print_range(field);
      break;
    }
  }
  terminate();
}

void GotoDefinitionHandler::this_(ast::Identifier* node,
                                  ir::Class* enclosing_class,
                                  IterableScope* scope,
                                  ir::Method* surrounding) {
  if (enclosing_class != null) {
    _print_range(enclosing_class);
  }
  terminate();
}

void GotoDefinitionHandler::show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  for (auto node : entry.nodes()) {
    if (node->is_Class()) _print_range(node->as_Class()->range());
    if (node->is_Method()) _print_range(node->as_Method()->range());
  }
  terminate();
}

void GotoDefinitionHandler::expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  for (auto node : entry.nodes()) {
    if (node->is_Class()) _print_range(node->as_Class()->range());
    if (node->is_Method()) _print_range(node->as_Method()->range());
  }
  terminate();
}

void GotoDefinitionHandler::return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) {
  if (label_index != -1) {
    // We don't want the whole range of the black/lambda, as VSCode wouldn't jump
    //   to the beginning. Just take the from position.
    auto from = labels[label_index].second->selection_range().from();
    _print_range(Source::Range(from, from));
  }
  terminate();
}

void GotoDefinitionHandler::toitdoc_ref(ast::Node* node,
                                        List<ir::Node*> candidates,
                                        ToitdocScopeIterator* iterator,
                                        bool is_signature_toitdoc) {
  // We are ok with resolving to many nodes (even ambiguous ones).
  // This will help the user to figure out why they have an error.
  _print_all(candidates);
  terminate();
}

void GotoDefinitionHandler::import_path(const char* path,
                                        const char* segment,
                                        bool is_first_segment,
                                        const char* resolved,
                                        const Package& current_package,
                                        const PackageLock& package_lock,
                                        Filesystem* fs) {
  if (resolved != null) {
    auto import_range = LspLocation {
      .path = resolved,
      .range = {
        .from_line = 0,
        .from_column= 0,
        .to_line= 0,
        .to_column = 0,
      },
    };
    protocol()->goto_definition()->emit(import_range);
  }
  terminate();
}

} // namespace toit::compiler
} // namespace toit


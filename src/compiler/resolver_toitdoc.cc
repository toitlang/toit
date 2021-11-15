// Copyright (C) 2018 Toitware ApS.
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

#include "../top.h"

#include "diagnostic.h"
#include "lsp.h"
#include "resolver_toitdoc.h"
#include "resolver_scope.h"

namespace toit {
namespace compiler {

static void ensure_has_toitdoc_scope(ir::Class* klass);

namespace {  // anonymous

/**
An iterator for everything directly after a `$`.

It sees everything, static or dynamic, as well as parameters.
*/
class LeftMostIterator : public ToitdocScopeIterator {
 public:
  LeftMostIterator(Scope* scope,
                   ast::Node* holder,
                   ir::Class* this_class,
                   List<ir::Node*> super_entries)
      : _scope(scope)
      , _holder(holder)
      , _this_class(this_class)
      , _super_entries(super_entries) { }

  void for_each(const std::function<void (Symbol)>& parameter_callback,
                const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    if (_holder != null && _holder->is_Method()) {
      auto method = _holder->as_Method();
      for (auto parameter : method->parameters()) {
        parameter_callback(parameter->name()->data());
      }
    }
    if (_this_class != null) {
      callback(Symbols::this_, ResolutionEntry(_this_class));
    }
    if (!_super_entries.is_empty()) {
      // For now just use the first entry we find.
      callback(Symbols::super, ResolutionEntry(_super_entries.first()));
    }
    _scope->for_each(callback);
  }

 private:
  Scope* _scope;
  ast::Node* _holder;
  ir::Class* _this_class;
  List<ir::Node*> _super_entries;
};

/**
An iterator for classes.

It sees both static and dynamic entries.
*/
class ClassIterator : public ToitdocScopeIterator {
 public:
  ClassIterator(ir::Class* klass)
      : _class(klass) { }

  void for_each(const std::function<void (Symbol)>& parameter_callback,
                const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    ensure_has_toitdoc_scope(_class);
    auto class_scope = _class->toitdoc_scope();
    class_scope->for_each(callback);
  }

 private:
  ir::Class* _class;
};

/**
An iterator for prefixes.
*/
class PrefixIterator : public ToitdocScopeIterator {
 public:
  PrefixIterator(ImportScope* import_scope)
      : _import_scope(import_scope) { }

  void for_each(const std::function<void (Symbol)>& parameter_callback,
                const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    _import_scope->for_each_external(callback);
  }

 private:
  ImportScope* _import_scope;
};

} // namespace anonymous

static void ensure_has_toitdoc_scope(ir::Class* klass) {
  if (klass->toitdoc_scope() != null) return;
  ScopeFiller filler;
  filler.add_all(klass->constructors());
  filler.add_all(klass->factories());
  filler.add_all(klass->methods());
  filler.add_all(klass->fields());
  auto scope = _new SimpleScope(null);
  filler.fill(scope);
  klass->statics()->for_each([&](Symbol name, const ResolutionEntry& entry) {
    scope->add(name, entry);
  });
  klass->set_toitdoc_scope(scope);
}

static ResolutionEntry lookup_super(ast::Node* holder, Scope* class_scope) {
  ResolutionEntry not_found;
  auto member_name = Symbol::invalid();
  if (holder->is_Method()) {
    auto method = holder->as_Method();
    if (method->is_static()) return not_found;
    auto name_or_dot = method->name_or_dot();
    if (name_or_dot->is_Identifier()) {
      // This should be the only valid case.
      member_name = name_or_dot->as_Identifier()->data();
    } else {
      // Shouldn't happen (as only statics can have dots.
      member_name = name_or_dot->as_Dot()->name()->data();
    }
  } else if (holder->is_Field()) {
    member_name = holder->as_Field()->name()->data();
  }
  // Note that a method could have an invalid name, but in that case we would exit
  //   early here too.
  if (!member_name.is_valid()) return not_found;
  // At the very least we need to the find the holder.
  auto entry = class_scope->lookup(member_name).entry;
  ASSERT(entry.kind() == ResolutionEntry::NODES);
  // TODO(florian): this work here is similar to the one we are doing
  //    in the MethodResolver::_compute_target_candidates.
  ListBuilder<ir::Node*> super_entries;
  bool found_super_separator = false;
  for (auto node : entry.nodes()) {
    if (node == ClassScope::SUPER_CLASS_SEPARATOR) {
      found_super_separator = true;
    } else if (found_super_separator) {
      super_entries.add(node);
    }
  }
  if (super_entries.is_empty()) return not_found;
  return ResolutionEntry(super_entries.build());
}

static ResolutionEntry lookup_toitdoc(ast::Node* ast_ref,
                                      ast::Node* holder,
                                      Scope* scope) {
  ResolutionEntry not_found;
  static_assert(Symbols::reserved_symbol_count == 4, "Unexpected reserved symbol count");
  if (ast_ref->is_Identifier() &&
      Symbols::is_reserved(ast_ref->as_Identifier()->data()) &&
      ast_ref->as_Identifier()->data() != Symbols::_) {
    auto symbol = ast_ref->as_Identifier()->data();
    auto class_scope = scope->enclosing_class_scope();
    if (class_scope == null) return not_found;
    if (symbol == Symbols::this_) return ResolutionEntry(class_scope->klass());
    if (symbol == Symbols::constructor) {
      auto klass = class_scope->klass();
      ensure_has_toitdoc_scope(klass);
      return klass->toitdoc_scope()->lookup(symbol).entry;
    }
    ASSERT(symbol == Symbols::super);
    return lookup_super(holder, class_scope);
  }
  if (ast_ref->is_Identifier()) {
    auto name = ast_ref->as_Identifier()->data();
    return scope->lookup(name).entry;
  }

  if (scope->is_prefixed_identifier(ast_ref) || scope->is_static_identifier(ast_ref)) {
    return scope->lookup_static_or_prefixed(ast_ref);
  }

  ASSERT(ast_ref->is_Dot());

  auto dot = ast_ref->as_Dot();
  // Try to see if this is referencing an element inside a class.
  auto receiver = dot->receiver();
  auto name = dot->name()->data();

  ResolutionEntry class_entry;
  if (receiver->is_Dot()) {
    if (scope->is_prefixed_identifier(receiver) ||
        scope->is_static_identifier(receiver)) {
      class_entry = scope->lookup_static_or_prefixed(receiver);
    } else {
      return not_found;
    }
  } else if (receiver->is_Identifier()) {
    auto identifier = receiver->as_Identifier();
    class_entry = scope->lookup(identifier->data()).entry;
  }
  if (!class_entry.is_class()) return not_found;
  auto klass = class_entry.klass();
  ensure_has_toitdoc_scope(klass);
  auto toitdoc_scope = klass->toitdoc_scope();
  return toitdoc_scope->lookup(name).entry;
}

static bool is_lsp_selection(ast::Node* node) {
  if (node->is_LspSelection()) return true;
  if (!node->is_Dot()) return false;
  auto dot = node->as_Dot();
  return is_lsp_selection(dot->receiver()) || is_lsp_selection(dot->name());
}

static bool left_most_is_selection(ast::Node* ast_target) {
  if (ast_target->is_LspSelection()) return true;
  if (!ast_target->is_Dot()) return false;
  return left_most_is_selection(ast_target->as_Dot()->receiver());;
}

static void call_lsp_handler(LspSelectionHandler* lsp_handler,
                             ast::ToitdocReference* ast_ref,
                             ast::Node* holder,
                             List<ir::Node*> candidates,
                             Scope* scope) {
  auto* ast_target = ast_ref->target();
  auto class_scope = scope->enclosing_class_scope();
  bool is_signature_reference = ast_ref->is_signature_reference();
  if (left_most_is_selection(ast_target)) {
    if (!ast_target->is_LspSelection()) {
      // The candidates are only for the last full entry.
      // We could resolve the receiver, but, for now, we just don't provide
      // any goto-definition for it.
      candidates = List<ir::Node*>();
    }

    ir::Class* this_class = class_scope != null ? class_scope->klass() : null;
    List<ir::Node*> super_entries;
    if (class_scope != null) super_entries = lookup_super(holder, class_scope).nodes();

    LeftMostIterator iterator(scope, holder, this_class, super_entries);
    lsp_handler->toitdoc_ref(ast_ref,
                             candidates,
                             &iterator,
                             is_signature_reference);
    return;
  }

  ASSERT(ast_target->is_Dot());
  auto dot = ast_target->as_Dot();

  // We already handled the case where the selection is the left-most segment.
  ASSERT(!dot->receiver()->is_LspSelection());

  if (dot->receiver()->is_Identifier()) {
    ASSERT(dot->name()->is_LspSelection());
    auto id = dot->receiver()->as_Identifier();
    auto entry = scope->lookup(id->data()).entry;
    PrefixIterator prefix_iterator(null);
    ClassIterator class_iterator(null);
    ToitdocScopeIterator* iterator = null;
    if (entry.is_prefix()) {
      prefix_iterator = PrefixIterator(entry.prefix());
      iterator = &prefix_iterator;
    } else if (entry.is_class()) {
      class_iterator = ClassIterator(entry.klass());
      iterator = &class_iterator;
    } else {
      return;
    }
    lsp_handler->toitdoc_ref(dot->name(),
                             candidates,
                             iterator,
                             is_signature_reference);
    return;
  }

  ASSERT(dot->receiver()->is_Dot());
  auto left_dot = dot->receiver()->as_Dot();
  if (!left_dot->receiver()->is_Identifier()) return;

  auto id = left_dot->receiver()->as_Identifier();
  auto entry = scope->lookup(id->data()).entry;
  if (!entry.is_prefix()) return;
  auto prefix = entry.prefix();
  if (left_dot->name()->is_LspSelection()) {
    PrefixIterator iterator(prefix);
    // The candidates aren't for this segment, but for the whole ast_ref node.
    // We could look up new candidates, but for now we just provide none.
    lsp_handler->toitdoc_ref(left_dot->name(),
                             List<ir::Node*>(),
                             &iterator,
                             is_signature_reference);
    return;
  }
  ASSERT(dot->name()->is_LspSelection());
  auto class_entry = scope->lookup_prefixed(left_dot);
  if (!class_entry.is_class()) return;
  ClassIterator iterator(class_entry.klass());
  lsp_handler->toitdoc_ref(dot->name(),
                           candidates,
                           &iterator,
                           is_signature_reference);
}


ir::Node* resolve_toitdoc_ref(ast::ToitdocReference* ast_ref,
                              ast::Node* holder,
                              Scope* scope,
                              LspSelectionHandler* lsp_handler,
                              const UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                              Diagnostics* diagnostics) {
  if (ast_ref->is_error()) return null;

  auto ast_target = ast_ref->target();
  auto call_shape = CallShape::invalid();
  if (ast_ref->is_signature_reference()) {
    // Use the call-builder to construct a call-shape that works.
    CallBuilder call_builder(ast_ref->range());

    // Create the fake values we pass to the builder.
    ir::LiteralNull literal_null(ast_ref->range());  // For non-block args.
    ir::Parameter fake_block_parameter(Symbol::synthetic("<fake-param>"),
                                        ir::Type::any(),
                                        true,  // Is block.
                                        0,
                                        false,
                                        ast_ref->range());
    ir::ReferenceLocal fake_block(&fake_block_parameter, 0, ast_ref->range());

    for (auto parameter : ast_ref->parameters()) {
      auto name = parameter->is_named()
          ? parameter->name()->data()
          : Symbol::invalid();
      ir::Expression* value = null;
      if (parameter->is_block()) {
        value = &fake_block;
      } else {
        value = &literal_null;
      }
      call_builder.add_argument(value, name);
    }
    call_shape = call_builder.shape();

    bool is_setter = ast_ref->is_setter();
    if (is_setter) {
      if (call_shape != CallShape(1)) {
        diagnostics->report_warning(ast_target,
                                    "A setter must take exactly one argument");
      }
      call_shape = CallShape(call_shape.arity(),
                              call_shape.total_block_count(),
                              call_shape.names(),
                              call_shape.named_block_count(),
                              is_setter);
    }
  } else if (ast_ref->is_setter()) {
    call_shape = CallShape::for_static_setter();
  }
  Symbol name = ast_target->is_Identifier()
      ? ast_target->as_Identifier()->data()
      : ast_target->as_Dot()->name()->data();
  auto entry = lookup_toitdoc(ast_target, holder, scope);

  // TODO(florian): do the same for parameters. (for example, for completion of named arguments).
  bool is_lsp = is_lsp_selection(ast_target);

  List<ir::Node*> goto_definition_targets;

  ir::Node* result = null;
  switch (entry.kind()) {
    case ResolutionEntry::PREFIX:
      // TODO(florian): maybe we want to change this, but definitely not for signature-refs.
      diagnostics->report_warning(ast_target,
                                  "Can't reference prefix '%s'",
                                  name.c_str());
      break;
    case ResolutionEntry::AMBIGUOUS:
      diagnostics->start_group();
      diagnostics->report_warning(ast_target,
                                  "Ambiguous resolution of reference '%s'",
                                  name.c_str());
      for (auto node : entry.nodes()) {
        // If the node is a parameter we can't easily find the ast-node (with the position)
        //   yet. That's not really a problem, as there would be an error for having
        //   parameters with the same name.
        if (!node->is_Parameter()) {
          // TODO(florian): if all ir-nodes had ranges, we wouldn't need to go through
          // the map.
          auto ast_node = ir_to_ast_map.at(node);
          diagnostics->report_warning(ast_node->range(),
                                      "Resolution candidate for '%s'",
                                      name.c_str());
        }
      }
      diagnostics->end_group();
      goto_definition_targets = entry.nodes();
      break;
    case ResolutionEntry::NODES: {
      if (entry.nodes().is_empty()) {
        diagnostics->report_warning(ast_target,
                                    "Unresolved reference '%s'",
                                    name.c_str());
        break;
      }
      if (!call_shape.is_valid()) {
        if (is_lsp) {
          ListBuilder<ir::Node*> candidates;
          for (auto node : entry.nodes()) {
            if (node == ClassScope::SUPER_CLASS_SEPARATOR) {
              // If we haven't found a match yet, find them in the super-class entries.
              if (candidates.is_empty()) continue;
              break;
            }
            candidates.add(node);
          }
          goto_definition_targets = candidates.build();
        }
        // For now just pick the first node.
        result = entry.nodes().first();
      } else {
        for (auto node : entry.nodes()) {
          if (node == ClassScope::SUPER_CLASS_SEPARATOR) {
            continue;
          }
          if (!node->is_Method()) continue;
          auto method = node->as_Method();
          auto method_shape = method->resolution_shape();
          if (method->has_implicit_this()) {
            method_shape = method_shape.without_implicit_this();
          }
          if (method_shape.accepts(call_shape)) {
            result = method;
            break;
          }
        }
        if (result == null) {
          diagnostics->report_warning(ast_target,
                                      "Can't resolve reference '%s' with the given shape",
                                      name.c_str());
          break;
        } else {
          goto_definition_targets = ListBuilder<ir::Node*>::build(result);
        }
      }
      if (result->is_FieldStub()) result = result->as_FieldStub()->field();
    }
  }
  if (is_lsp) {
    call_lsp_handler(lsp_handler,
                     ast_ref,
                     holder,
                     goto_definition_targets,
                     scope);
  }
  return result;
}

Toitdoc<ir::Node*> resolve_toitdoc(Toitdoc<ast::Node*> ast_toitdoc,
                                   ast::Node* holder,
                                   Scope* scope,
                                   LspSelectionHandler* lsp_handler,                                    const UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                                   Diagnostics* diagnostics) {
  auto ast_refs = ast_toitdoc.refs();
  auto resolved = ListBuilder<ir::Node*>::allocate(ast_refs.length());
  for (int i = 0; i < ast_refs.length(); i++) {
    auto ast_node = ast_refs[i];
    ASSERT(ast_node->is_ToitdocReference());
    auto ast_ref = ast_node->as_ToitdocReference();
    resolved[i] = resolve_toitdoc_ref(ast_ref, holder, scope, lsp_handler, ir_to_ast_map, diagnostics);
  }
  return Toitdoc<ir::Node*>(ast_toitdoc.contents(), resolved, ast_toitdoc.range());
}

} // namespace toit::compiler
} // namespace toit

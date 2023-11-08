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

#include "completion.h"

#include "../lock.h"
#include "../resolver_scope.h"
#include "../resolver_toitdoc.h"
#include "../resolver_primitive.h"
#include "../set.h"
#include "../token.h"

namespace toit {
namespace compiler {

void CompletionHandler::class_interface_or_mixin(ast::Node* node,
                                                 IterableScope* scope,
                                                 ir::Class* holder,
                                                 ir::Node* resolved,
                                                 bool needs_interface,
                                                 bool needs_mixin) {
  scope->for_each([&](Symbol name, const ResolutionEntry& entry) {
    if (entry.is_class()) {
      auto klass = entry.klass();
      if ((needs_interface && !klass->is_interface()) || (!needs_interface && klass->is_interface())) return;
      if ((needs_mixin && !klass->is_mixin()) || (!needs_mixin && klass->is_mixin())) return;
      if (klass == holder) return;
      complete_entry(name, entry);
    } else if (entry.is_prefix()) {
      complete_entry(name, entry);
    }
  });
  exit(0);
}

static CompletionKind completion_kind_for(ir::Class* klass) {
  switch (klass->kind()) {
    case ir::Class::CLASS:
    case ir::Class::MONITOR:
    case ir::Class::MIXIN:
      return CompletionKind::CLASS;
    case ir::Class::INTERFACE:
      return CompletionKind::INTERFACE;
      break;
  }
  UNREACHABLE();
}

void CompletionHandler::type(ast::Node* node,
                             IterableScope* scope,
                             ResolutionEntry resolved,
                             bool allow_none) {
  Set<std::string> important_core_types;

  if (!scope->is_prefixed_scope()) {
    complete("any", CompletionKind::KEYWORD);
    if (allow_none) complete("none", CompletionKind::KEYWORD);
    complete("bool", CompletionKind::CLASS);
    complete("int", CompletionKind::CLASS);
    complete("float", CompletionKind::CLASS);
    // The following are just commonly used and should appear early in the list.
    important_core_types.insert("String");
    important_core_types.insert("Map");
    important_core_types.insert("List");
    important_core_types.insert("Set");
  }

  for (auto core_type : important_core_types) {
    complete(core_type, CompletionKind::CLASS);
  }
  scope->for_each([&](Symbol name, const ResolutionEntry& entry) {
    if (entry.is_class()) {
      if (!important_core_types.contains(name.c_str())) {
        // We don't use `complete_entry` here, as we want classes to be
        //   shown as classes and not as constructors.
        auto klass = entry.klass();
        complete_entry(name, entry, completion_kind_for(klass));
      }
    } else if (entry.is_prefix()) {
      complete_entry(name, entry);
    }
  });
  exit(0);
}

void CompletionHandler::call_virtual(ir::CallVirtual* node,
                                     ir::Type type,
                                     List<ir::Class*> classes) {
  bool is_for_named = node->target()->as_LspSelectionDot()->is_for_named();
  if (type.is_none()) {
    // No completions.
    exit(0);
  }
  if (type.is_any()) {
    // No completions. Just let the client suggest identifiers it has seen.
    exit(0);
  }
  ASSERT(type.is_class());
  auto klass = type.klass();
  if (is_for_named) {
    auto selector = node->selector();
    while (klass != null) {
      for (int i = -1; i < klass->mixins().length(); i++) {
        auto current = i == -1
            ? klass
            : klass->mixins()[i];
        for (auto method : current->methods()) {
          if (method->name() == selector) {
            complete_named_args(method);
          }
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
    exit(0);
  }

  while (klass != null) {
    for (int i = -1; i < klass->mixins().length(); i++) {
      auto current = i == -1
          ? klass
          : klass->mixins()[i];
      auto class_source = source_manager_->source_for_position(current->range().from());
      auto class_package = class_source->package_id();
      for (auto method : current->methods()) {
        complete_method(method, class_package);
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
  exit(0);
}

void CompletionHandler::complete_static_ids(IterableScope* scope,
                                            ir::Method* surrounding) {
  bool has_access_to_this = surrounding == null || surrounding->is_instance() || surrounding->is_constructor();
  scope->for_each([=](Symbol name, const ResolutionEntry& entry) {
    switch (entry.kind()) {
      case ResolutionEntry::Kind::PREFIX:
        complete_entry(name, entry);
        break;
      case ResolutionEntry::Kind::NODES: {
        // We just look at the first one, and assume that all others are of the same type.
        auto node = entry.nodes().first();
        bool is_instance_method = node->is_Method() && node->as_Method()->is_instance();
        if (has_access_to_this || !is_instance_method) {
          complete_entry(name, entry);
        }
        break;
      }
      case ResolutionEntry::Kind::AMBIGUOUS:
        // Don't do anything for now.
        break;
    }
  });
}

void CompletionHandler::call_static(ast::Node* node,
                                    ir::Node* resolved1,
                                    ir::Node* resolved2,
                                    List<ir::Node*> candidates,
                                    IterableScope* scope,
                                    ir::Method* surrounding) {
  complete("true", CompletionKind::KEYWORD);
  complete("false", CompletionKind::KEYWORD);
  complete("null", CompletionKind::KEYWORD);
  complete("return", CompletionKind::KEYWORD);
  complete_static_ids(scope, surrounding);
  exit(0);
}

void CompletionHandler::call_prefixed(ast::Dot* node,
                                      ir::Node* resolved1,
                                      ir::Node* resolved2,
                                      List<ir::Node*> candidates,
                                      IterableScope* scope) {
  scope->for_each([&](Symbol name, const ResolutionEntry& entry) {
    switch (entry.kind()) {
      case ResolutionEntry::Kind::PREFIX:
        // Don't propose prefixes.
        return;
      case ResolutionEntry::Kind::NODES:
        complete_entry(name, entry);
        break;
      case ResolutionEntry::Kind::AMBIGUOUS:
        UNREACHABLE();
    }
  });
}

void CompletionHandler::call_class(ast::Dot* node,
                                   ir::Class* klass,
                                   ir::Node* resolved1,
                                   ir::Node* resolved2,
                                   List<ir::Node*> candidates,
                                   IterableScope* scope) {
  bool has_default_constructor = false;
  CallShape default_constructor_shape(1);  // 1 argument for `this`.
  for (auto constructor : klass->unnamed_constructors()) {
    if (constructor->resolution_shape().accepts(default_constructor_shape)) {
      has_default_constructor = true;
      break;
    }
  }
  if (!has_default_constructor) {
    CallShape default_factory_shape(0);
    for (auto factory : klass->factories()) {
      if (factory->resolution_shape().accepts(default_factory_shape)) {
        has_default_constructor = true;
        break;
      }
    }
  }

  klass->statics()->for_each([&](Symbol name, const ResolutionEntry& entry) {
    complete_entry(name, entry);
  });
  exit(0);
}

void CompletionHandler::call_block(ast::Dot* node, ir::Node* ir_receiver) {
  complete("call", CompletionKind::METHOD);
}

void CompletionHandler::call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) {
  // For simplicity just run through all candidates and list *all* named options.
  // TODO(florian): only allow valid combinations of names.
  for (auto candidate : candidates) {
    if (!candidate->is_Method()) continue;
    complete_named_args(candidate->as_Method());
  }
  exit(0);
}

void CompletionHandler::call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                                       int module, int primitive, bool on_module) {
  // TODO(florian): the intrinsics don't really fit yet.
  if (on_module) {
    complete("intrinsics", CompletionKind::MODULE);
    int module_count = PrimitiveResolver::number_of_modules();
    for (int i = 0; i < module_count; i++) {
      complete(PrimitiveResolver::module_name(i), CompletionKind::MODULE);
    }
  } else if (module_name == Symbols::intrinsics) {
    complete("array_do", CompletionKind::PROPERTY);
    complete("hash_find", CompletionKind::PROPERTY);
    complete("hash_do", CompletionKind::PROPERTY);
    complete("smi_repeat", CompletionKind::PROPERTY);
    complete("main", CompletionKind::PROPERTY);
  } else if (module != -1) {
    int primitive_count = PrimitiveResolver::number_of_primitives(module);
    for (int i = 0; i < primitive_count; i++) {
      complete(PrimitiveResolver::primitive_name(module, i), CompletionKind::PROPERTY);
    }
  }
  exit(0);
}

void CompletionHandler::field_storing_parameter(ast::Parameter* node,
                                                List<ir::Field*> fields,
                                                bool field_storing_is_allowed) {
  if (field_storing_is_allowed) {
    for (auto field : fields) {
      auto name = field->name();
      if (!name.is_valid()) continue;
      complete(field->name(), CompletionKind::FIELD);
    }
  }
  exit(0);
}

void CompletionHandler::this_(ast::Identifier* node,
                              ir::Class* enclosing_class,
                              IterableScope* scope,
                              ir::Method* surrounding) {
  call_static(node, null, null, List<ir::Node*>(), scope, surrounding);
  exit(0);
}

void CompletionHandler::show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  if (scope == null) return;
  UnorderedSet<ModuleScope*> already_visited;
  scope->for_each_external([&](Symbol name, const ResolutionEntry& entry) {
    complete_entry(name, entry);
  }, &already_visited);
  exit(0);
}

void CompletionHandler::return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) {
  for (int i = labels.size() - 1; i >= 0; i--) {
    auto label = labels[i].first;
    // TODO(florian): check LSP spec in the future to see if a better kind was added.
    if (label.is_valid()) complete(label, CompletionKind::KEYWORD);
    if (labels[i].second->is_Lambda()) break;
  }
  exit(0);
}

void CompletionHandler::toitdoc_ref(ast::Node* node,
                                    List<ir::Node*> candidates,
                                    ToitdocScopeIterator* iterator,
                                    bool is_signature_toitdoc) {
  // TODO(florian): prefer parameters.
  auto param_callback = [&](Symbol param) {
    complete(param, CompletionKind::VARIABLE);
  };
  auto other_callback = [&](Symbol name, const ResolutionEntry& entry) {
    complete_entry(name, entry);
  };
  iterator->for_each(param_callback, other_callback);
  exit(0);
}

void CompletionHandler::import_first_segment(Symbol prefix,
                                             ast::Identifier* segment,
                                             const Package& current_pkg,
                                             const PackageLock& package_lock,
                                             LspProtocol* protocol) {
  CompletionHandler handler(prefix, current_pkg.id(), null, protocol);
  current_pkg.list_prefixes([&](const std::string& candidate) {
    handler.complete(candidate.c_str(), CompletionKind::MODULE);
  });
  package_lock.list_sdk_prefixes([&](const std::string& candidate) {
    handler.complete(candidate.c_str(), CompletionKind::MODULE);
  });
  exit(0);
}

void CompletionHandler::import_path(Symbol prefix,
                                    const char* path,
                                    Filesystem* fs,
                                    LspProtocol* protocol) {
  CompletionHandler handler(prefix, Package::INVALID_PACKAGE_ID, null, protocol);
  fs->list_toit_directory_entries(path, [&](const char* candidate, bool is_directory) {
    handler.complete(candidate, CompletionKind::MODULE);
  });
  exit(0);
}

static bool is_constant_name(Symbol name) {
  if (!name.is_valid()) return false;
  const char* ptr = name.c_str();
  // Must start with capitalized character.
  if (!isupper(*ptr)) return false;
  while (*ptr != '\0') {
    if (!(*ptr == '_' || *ptr == '-' || isupper(*ptr))) return false;
    ptr++;
  }
  return true;
}

void CompletionHandler::complete_named_args(ir::Method* method) {
  auto shape = method->resolution_shape();
  for (auto name : shape.names()) {
    // TODO(florian): only insert `=` if it's not a boolean flag.
    // TODO(florian): check LSP spec in the future to see if a better kind than KEYWORD
    //   was added. Suggested a 'named argument' kind here:
    //   https://github.com/microsoft/language-server-protocol/issues/343#issuecomment-661786310
    complete(std::string(name.c_str()) + "=", CompletionKind::KEYWORD);
  }
}

bool is_private(Symbol name) {
  if (!name.is_valid()) return false;
  int len = strlen(name.c_str());
  return name.c_str()[len - 1] == '_';
}

void CompletionHandler::complete_method(ir::Method* method, const std::string& package_id) {
  complete_if_visible(method->name(), CompletionKind::METHOD, package_id);
}

void CompletionHandler::complete_entry(Symbol name,
                                       const ResolutionEntry& entry,
                                       CompletionKind kind_override) {
  switch (entry.kind()) {
    case ResolutionEntry::Kind::PREFIX:
      // TODO(florian): check LSP spec in the future to see if a better kind was added.
      complete(name, CompletionKind::MODULE);
      return;

    case ResolutionEntry::Kind::AMBIGUOUS:
    case ResolutionEntry::Kind::NODES:
      if (entry.is_empty()) {
        // Can this even happen?
        complete(name, CompletionKind::NONE);
        return;
      }
      break;
  }
  ASSERT(entry.kind() == ResolutionEntry::Kind::NODES ||
         entry.kind() == ResolutionEntry::Kind::AMBIGUOUS);
  ASSERT(!entry.is_empty());

  // If there are several entries, we just pick the first one.
  // TODO(florian): we should provide different entries, when there are
  //    different kinds or signatures.
  auto node = entry.nodes()[0];

  auto range = Source::Range::invalid();
  auto kind = CompletionKind::NONE;

  if (node->is_Class()) {
    auto klass = node->as_Class();
    kind = completion_kind_for(klass);
    range = klass->range();
  } else if (node->is_Field()) {
    range = node->as_Field()->range();
    kind = CompletionKind::FIELD;
  } else if (node->is_FieldStub()) {
    range = node->as_FieldStub()->range();
    kind = CompletionKind::FIELD;
  } else if (node->is_Local()) {
    // In theory we could avoid the visibility check, as the
    // local must be in the same package.
    range = node->as_Local()->range();
    kind = CompletionKind::VARIABLE;
  } else if (node->is_Global()) {
    auto global = node->as_Global();
    range = global->range();
    // TODO(florian): not sure these are the best completion kinds.
    if (global->is_final() && is_constant_name(name)) {
      kind = CompletionKind::CONSTANT;
    } else {
      kind = CompletionKind::VARIABLE;
    }
  } else if (node->is_Method()) {
    auto method = node->as_Method();
    range = method->range();
    if (method->is_constructor() || method->is_factory()) {
      kind = CompletionKind::CONSTRUCTOR;
    } else if (method->is_instance()) {
      kind = CompletionKind::METHOD;
    } else {
      kind = CompletionKind::FUNCTION;
    }
  }
  if (kind_override != CompletionKind::NONE) {
    kind = kind_override;
  }
  std::string package_id = Package::INVALID_PACKAGE_ID;
  if (range.is_valid()) {
    package_id = source_manager_->source_for_position(range.from())->package_id();
  }
  complete_if_visible(name, kind, package_id);
}

void CompletionHandler::complete_if_visible(Symbol name,
                                            CompletionKind kind,
                                            const std::string& package_id) {
  if (package_id_ == package_id || !is_private(name)) {
    complete(name, kind);
  }
}

void CompletionHandler::complete(const std::string& name, CompletionKind kind) {
  if (emitted.contains(name)) return;
  // Filter out completions that don't match the prefix.
  if (strncmp(name.c_str(), prefix_.c_str(), strlen(prefix_.c_str())) != 0) return;
  emitted.insert(name);
  protocol()->completion()->emit(name, kind);
}


} // namespace toit::compiler
} // namespace toit

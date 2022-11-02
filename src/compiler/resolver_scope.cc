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

#include "resolver_scope.h"

#include "ast.h"
#include "set.h"

namespace toit {
namespace compiler {

constexpr ir::Node* ClassScope::SUPER_CLASS_SEPARATOR;

/// Returns the ImportScope for the given node.
///
/// Returns `null` if the given node is not a [Prefix].
ImportScope* Scope::_find_import_scope(ast::Node* node) {
  if (node == _find_import_scope_node_cache) {
    return find_import_scope_result_cache_;
  }
  if (!node->is_Identifier()) return null;

  _find_import_scope_node_cache = node;
  find_import_scope_result_cache_ = null;
  auto prefix_name = node->as_Identifier()->data();

  auto lookup_result = lookup(prefix_name);
  if (!lookup_result.entry.is_prefix()) return null;

  ImportScope* result = lookup_result.entry.prefix();
  find_import_scope_result_cache_ = result;
  return result;
}

bool Scope::is_prefixed_identifier(ast::Node* node) {
  if (!node->is_Dot()) return false;
  auto ast_dot = node->as_Dot();
  auto prefix = _find_import_scope(ast_dot->receiver());
  return prefix != null;
}

bool Scope::is_static_identifier(ast::Node* node) {
  return !lookup_static(node).is_empty();
}

ResolutionEntry Scope::lookup_static_or_prefixed(ast::Node* node) {
  auto result = lookup_prefixed(node);
  if (!result.is_empty()) return result;
  return lookup_static(node);
}

ResolutionEntry Scope::lookup_static(ast::Node* node) {
  if (node == _lookup_static_node_cache) {
    return lookup_static_result_cache_;
  }

  ResolutionEntry not_found;
  _lookup_static_node_cache = node;
  lookup_static_result_cache_ = not_found;

  if (!node->is_Dot()) return not_found;
  auto ast_dot = node->as_Dot();
  auto ast_receiver = ast_dot->receiver();
  if (!ast_receiver->is_Dot() && !ast_receiver->is_Identifier()) return not_found;
  ResolutionEntry entry;
  if (ast_receiver->is_Identifier()) {
    entry = lookup(ast_receiver->as_Identifier()->data()).entry;
  } else {
    // If this is a static, we have something like `prefix.Class.statik`.
    // The ast_receiver_dot is now `prefix.Class`.
    entry = lookup_prefixed(ast_receiver);
  }
  if (!entry.is_class()) return not_found;
  auto ir_class = entry.klass();
  auto result = ir_class->statics()->lookup(ast_dot->name()->data());
  lookup_static_result_cache_ = result;
  return result;
}

ResolutionEntry Scope::lookup_prefixed(ast::Node* node) {
  if (node == _lookup_prefix_node_cache) {
    return lookup_prefix_result_cache_;
  }

  ResolutionEntry not_found;
  _lookup_prefix_node_cache = node;
  lookup_prefix_result_cache_ = not_found;

  if (!node->is_Dot()) return not_found;
  auto ast_dot = node->as_Dot();
  auto prefix = _find_import_scope(ast_dot->receiver());
  if (prefix == null) return not_found;
  UnorderedSet<ModuleScope*> already_visited;
  auto result = prefix->lookup(ast_dot->name()->data(), &already_visited);
  lookup_prefix_result_cache_ = result;
  return result;
}


ResolutionEntry ImportScope::lookup(Symbol name,
                                    bool is_external,
                                    UnorderedSet<ModuleScope*>* already_visited) {
  Scope::ResolutionEntryMap* cache;
  if (is_external) {
    cache = &cache_external_;
  } else {
    cache = &cache_;
  }

  {
    // Try the cache first.
    auto probe = cache->find(name);
    if (probe != cache->end()) return probe->second;
  }

  // Try to find the identifier in the imported scopes.
  ResolutionEntry entry;
  Set<ir::Node*> ambiguous_nodes;
  for (auto scope : imported_scopes_) {
    if (is_external && !explicitly_imported_.contains(scope)) continue;
    auto module_entry = scope->lookup_external(name, already_visited);
    switch (module_entry.kind()) {
      case ResolutionEntry::PREFIX: UNREACHABLE(); break;
      case ResolutionEntry::AMBIGUOUS:
        // Just forward the ambiguous entry. No need to add more
        // nodes from this module.
        entry = module_entry;
        goto end_scope_loop;
      case ResolutionEntry::NODES:
        if (!module_entry.is_empty()) {
          if (entry.is_empty()) {
            entry = module_entry;
            continue;
          }
          if (entry.nodes()[0] == module_entry.nodes()[0]) {
            ASSERT(entry.kind() == ResolutionEntry::NODES ||
                   entry.kind() == ResolutionEntry::AMBIGUOUS);
            // We found the same entry again.
            continue;
          }
          // Different entries. A clash.
          switch (entry.kind()) {
            case ResolutionEntry::PREFIX: UNREACHABLE(); break;
            case ResolutionEntry::NODES:
              // Replace the current entry with an ambiguous one and store
              // the first nodes of the ambiguous entries.
              // We will update the nodes in the entry at the end of the loop.
              ambiguous_nodes.insert(entry.nodes()[0]);
              ambiguous_nodes.insert(module_entry.nodes()[0]);
              entry = ResolutionEntry(ResolutionEntry::AMBIGUOUS);
              break;
            case ResolutionEntry::AMBIGUOUS:
              // Just add the new-found entry to the list of ambiguous nodes.
              ambiguous_nodes.insert(module_entry.nodes()[0]);
              break;
          }
        }
    }
  }
  if (entry.kind() == ResolutionEntry::AMBIGUOUS) {
    ASSERT(entry.nodes().is_empty());
    ASSERT(ambiguous_nodes.size() >= 2);
    entry.set_nodes(ambiguous_nodes.to_list());
  }
  end_scope_loop:
  // Only cache if it actually helps.
  if (imported_scopes_.size() > 1) {
    (*cache)[name] = entry;
  }
  return entry;
}

void ImportScope::for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                           bool is_external,
                           UnorderedSet<ModuleScope*>* already_visited) {
  for (auto scope : imported_scopes_) {
    if (is_external && !explicitly_imported_.contains(scope)) continue;
    scope->for_each_external(callback, already_visited);
  }
}

ResolutionEntry ModuleScope::lookup_external(Symbol name,
                                             UnorderedSet<ModuleScope*>* already_visited) {
  // Avoid infinite cycles.
  if (already_visited->contains(this)) return ResolutionEntry();

  auto probe = module_declarations_.find(name);
  if (probe != module_declarations_.end()) return probe->second;

  ASSERT(_exported_identifiers_map_has_been_set);
  probe = exported_identifiers_map_.find(name);
  if (probe != exported_identifiers_map_.end()) return probe->second;
  if (export_all_) {
    already_visited->insert(this);
    auto entry = non_prefixed_imported_->lookup_external(name, already_visited);
    already_visited->erase(this);
    switch (entry.kind()) {
      // Prefixes are not exported.
      case ResolutionEntry::PREFIX:
        // Prefixes are not exported and are ignored for the purpose of
        // import-lookups. As such they might shadow other imported nodes.
        return ResolutionEntry();
      case ResolutionEntry::AMBIGUOUS:
      case ResolutionEntry::NODES:
        return entry;
    }
    UNREACHABLE();
    return ResolutionEntry();
  } else {
    return lookup_module(name);
  }
}

void ModuleScope::for_each_external(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                                    UnorderedSet<ModuleScope*>* already_visited) {
  // Avoid infinite cycles.
  if (already_visited->contains(this)) return;

  ASSERT(_exported_identifiers_map_has_been_set);
  module_declarations_.for_each(callback);
  exported_identifiers_map_.for_each(callback);
  if (export_all_) {
    already_visited->insert(this);
    non_prefixed_imported_->for_each_external(callback, already_visited);
    already_visited->erase(this);
  }
}

} // namespace toit::compiler
} // namespace toit

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

#pragma once

#include <functional>

#include "ast.h"
#include "ir.h"
#include "map.h"
#include "symbol.h"
#include "set.h"

namespace toit {
namespace compiler {

class ImportScope;
class ClassScope;
class ModuleScope;
class Scope;


/// A Module represents a single source file.
///
/// It contains classes, methods and globals.
///
/// Imports are split in three categories:
///  1. transitive modules: imports that are transitively exported.
///  2. local modules: imports that are only visible in the current module.
///  3. prefixed modules: prefixed imports. These are only visible in the current module.
class Module {
 public:
  struct PrefixedModule {
    ast::Identifier* prefix;  // Prefix. `null` if there is none.
    Module* module;
    List<ast::Identifier*> show_identifiers;
    ast::Import* import;  // For error-reporting. For the core import it is `null`.
    bool is_explicitly_imported;
  };

  Module(ast::Unit* unit,
         List<ir::Class*> classes,
         List<ir::Method*> methods,
         List<ir::Global*> globals,
         bool export_all,
         const Set<Symbol>& exported_identifiers)
      : unit_(unit)
      , classes_(classes)
      , methods_(methods)
      , globals_(globals)
      , export_all_(export_all)
      , exported_identifiers_(exported_identifiers)
      , scope_(null) { }

  ast::Unit* unit() const { return unit_; }

  List<ir::Class*> classes() const { return classes_; }
  List<ir::Method*> methods() const { return methods_; }
  List<ir::Global*> globals() const { return globals_; }

  // Imported modules are not exported. They may have a prefix.
  //
  // The returned list is sorted, so that modules without prefix are first.
  List<PrefixedModule> imported_modules() const { return imported_modules_; }
  void set_imported_modules(List<PrefixedModule> modules) {
    ASSERT(_non_prefixed_are_first(modules));
    imported_modules_ = modules;
  }

  bool export_all() const { return export_all_; }
  Set<Symbol> exported_identifiers() const { return exported_identifiers_; }

  ModuleScope* scope() const { return scope_; }
  void set_scope(ModuleScope* scope) { scope_ = scope; }

  bool is_error_module() const { return unit_->is_error_unit(); }

 private:
  ast::Unit* unit_;
  List<ir::Class*> classes_;
  List<ir::Method*> methods_;
  List<ir::Global*> globals_;

  List<PrefixedModule> imported_modules_;
  bool export_all_;
  Set<Symbol> exported_identifiers_;

  ModuleScope* scope_;

  static bool _non_prefixed_are_first(List<PrefixedModule> modules) {
    if (modules.is_empty()) return true;
    int i = 0;
    while (i < modules.length() && modules[i].prefix == null) i++;
    for (; i < modules.length(); i++) {
      if (modules[i].prefix == null) return false;
    }
    return true;
  }
};

/// A ResolutionEntry is the entry in Scope-maps.
///
/// An entry can either contain IR-nodes, or a Prefix.
///
/// If the entry contains more than a single node, it resolved to an overloaded method.
class ResolutionEntry {
 public:
  enum Kind {
    NODES,
    PREFIX,
    AMBIGUOUS,
  };

  ResolutionEntry() : kind_(NODES), nodes_(List<ir::Node*>()) { }
  explicit ResolutionEntry(List<ir::Node*> nodes)
      : kind_(NODES), nodes_(nodes) { }
  explicit ResolutionEntry(ir::Node* node)
      : kind_(NODES), nodes_(ListBuilder<ir::Node*>::build(node)) { }

  explicit ResolutionEntry(ImportScope* prefix) : kind_(PREFIX), prefix_(prefix) { }

  // Used for ambiguous nodes.
  explicit ResolutionEntry(Kind kind) : kind_(kind), nodes_(List<ir::Node*>()) { }

  Kind kind() const { return kind_; }

  List<ir::Node*> nodes() const {
    ASSERT(kind_ == NODES || kind_ == AMBIGUOUS);
    return nodes_;
  }
  void set_nodes(List<ir::Node*> nodes) {
    ASSERT(kind_ == NODES || kind_ == AMBIGUOUS);
    nodes_ = nodes;
  }

  bool is_empty() const {
    return kind_ == NODES && nodes_.is_empty();
  }

  bool is_class() const {
    return kind_ == NODES &&
        nodes_.length() == 1 &&
        (nodes_[0]->is_Class() || nodes_[0]->is_Constructor());
  }

  ir::Class* klass() const {
    ASSERT(is_class());
    if (nodes_[0]->is_Class()) return nodes_[0]->as_Class();
    return nodes_[0]->as_Constructor()->klass();
  }

  bool is_single() const { return kind_ == NODES && nodes_.length() == 1; }
  ir::Node* single() const {
    ASSERT(is_single());
    return nodes_[0];
  }

  bool is_prefix() const { return kind_ == PREFIX; }

  ImportScope* prefix() const {
    ASSERT(kind_ == PREFIX);
    return prefix_;
  }

 private:
  Kind kind_;
  union {
    List<ir::Node*> nodes_;
    ImportScope* prefix_;
  };
};

class IterableScope {
 public:
  /// Invokes the given callback for each entry.
  ///
  /// Visits all entries that would have been considered for a `lookup`.
  ///
  /// Visits nested entries first. If a lookup would be ambiguous (for example,
  ///   with two `import .. show *`, then the order is non-specified.
  ///
  /// Also invokes the callback on shadowed declarations. That is, the function does not
  ///   keep track of which identifiers have already been seen.
  virtual void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) = 0;

  virtual bool is_prefixed_scope() const { return false; }
};

/// A simple instance of IterableScope that filters the results of another scope.
class FilteredIterableScope : public IterableScope {
 public:
  FilteredIterableScope(IterableScope* wrapped,
                        std::function<bool (Symbol, const ResolutionEntry&)> predicate)
      : wrapped_(wrapped)
      , predicate_(predicate) { }

  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    wrapped_->for_each([&] (Symbol symbol, const ResolutionEntry& entry) {
      if (predicate_(symbol, entry)) callback(symbol, entry);
    });
  }

 private:
  IterableScope* wrapped_;
  std::function<bool (Symbol, const ResolutionEntry&)> predicate_;
};

class Scope : public IterableScope {
 public:
  typedef Map<Symbol, ResolutionEntry> ResolutionEntryMap;

  /// When doing lookups in scopes, the result also includes the block depth.
  /// The block depth is 0 for global variables and functions.
  typedef struct LookupResult {
    ResolutionEntry entry;
    int block_depth;
  } LookupResult;

  explicit Scope(Scope* outer) : outer_(outer) { }

  virtual void add(Symbol name, ResolutionEntry entry) = 0;

  /// Resolves the given [name] in the given scope, including all outer scopes.
  ///
  /// At the top-level continues the lookup in the imported modules.
  virtual LookupResult lookup(Symbol name){
    auto entry = lookup_shallow(name);
    if (!entry.is_empty() || outer() == null) {
      return {
        .entry = entry,
        .block_depth = 0
      };
    }
    return outer()->lookup(name);
  }

  /// Finds the given entry, *without* trying to find it in outer scopes.
  ///
  /// For module scopes this still includes all imports.
  virtual ResolutionEntry lookup_shallow(Symbol name) = 0;

  /// Invokes the given callback for each entry.
  ///
  /// Visits all entries that would have been considered for `lookup`.
  ///
  /// Visits nested entries first. If a lookup would be ambiguous (for example,
  ///   with two `import .. show *`, then the order is non-specified.
  ///
  /// Also invokes the callback on shadowed declarations. That is, the function does not
  ///   keep track of which identifiers have already been seen.
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    for_each_shallow(callback);
    if (outer() != null) outer()->for_each(callback);
  }

  /// Invokes the given callback for each entry in the current scope *without*
  ///   recursing to the outer scopes.
  ///
  /// For module scopes still invokes the callback with the imported declarations.
  virtual void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) = 0;

  /// Returns the enclosing class scope (if it exists).
  virtual ClassScope* enclosing_class_scope() = 0;

  /// Returns the enclosing module scope.
  ///
  /// Every scope has a surrounding module-scope (representing the top-level).
  virtual ModuleScope* module_scope() { return outer()->module_scope(); }

  Scope* outer() const { return outer_; }

  /// Whether the given [node] is a prefixed identifier of the form `prefix.identifier` where
  /// the `prefix` is a module prefix.
  ///
  /// The `identifier` may not be in the prefix-scope.
  bool is_prefixed_identifier(ast::Node* node);

  /// Whether the given [node] is a static identifier qualified through the class-name that
  /// contains the static identifier. For example `A.foo`.
  ///
  /// Only returns true, if the node can be resolved to a static entry.
  /// For example:
  ///    class A
  ///      foo
  ///        print 499
  ///      static bar
  ///        print 42
  ///
  /// In this case `A.foo` would return false, but `A.bar` would return true.
  bool is_static_identifier(ast::Node* node);

  ResolutionEntry lookup_static_or_prefixed(ast::Node* node);

  /// Resolves the given [node] if it is a prefixed variable (as in [is_prefixed_identifier]).
  ///
  /// If the node is not a prefixed identifier, returns an empty resolution entry.
  ResolutionEntry lookup_prefixed(ast::Node* node);

  /// Resolves the given [node] if it is a static variable (as in [is_static_identifier]).
  ///
  /// If the node is not a static identifier, returns an empty resolution entry.
  ResolutionEntry lookup_static(ast::Node* node);

 private:
  Scope* outer_;

  ImportScope* _find_import_scope(ast::Node* node);

  ast::Node* find_import_scope_node_cache_ = null;
  ImportScope* find_import_scope_result_cache_ = null;
  ast::Node* lookup_static_node_cache_ = null;
  ResolutionEntry lookup_static_result_cache_;
  ast::Node* lookup_prefix_node_cache_ = null;
  ResolutionEntry lookup_prefix_result_cache_;
};

/// A scope (but not implementing the `Scope` interface) for static declarations
///   inside a class.
/// Toplevel statics are handled in ModuleScopes.
class StaticsScope : public IterableScope {
 public:
  StaticsScope() : map_is_valid_(true) { }

  void add(Symbol name, const ResolutionEntry& entry) {
    ASSERT(map_is_valid_);
    entries_[name] = entry;
    for (auto node : entry.nodes()) {
      ASSERT(node->is_Method());
      nodes_.push_back(node->as_Method());
    }
  }

  /// Looks up the corresponding name in the prefixes and imported modules.
  ResolutionEntry lookup(Symbol name) {
    ASSERT(map_is_valid_);
    auto probe = entries_.find(name);
    if (probe != entries_.end()) return probe->second;
    return ResolutionEntry();
  }

  /// Invokes the given [callback] on each entry that could be found via [lookup].
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    ASSERT(map_is_valid_);
    entries_.for_each(callback);
  }

  std::vector<ir::Method*> nodes() const { return nodes_; }
  void replace_nodes(const std::vector<ir::Method*>& new_nodes) {
    ASSERT(!map_is_valid_);
    nodes_ = new_nodes;
  }

  void invalidate_resolution_map() {
    entries_.clear();
    map_is_valid_ = false;
  }

  Scope::ResolutionEntryMap entries() const { return entries_; }

  bool is_prefixed_scope() const { return true; }

 private:
  bool map_is_valid_;
  Scope::ResolutionEntryMap entries_;
  // The nodes are redundant (since they are already in the entries_ map), but
  // this simplifies the code a lot.
  std::vector<ir::Method*> nodes_;
};

/// One or more imported modules with the same prefix.
///
/// The prefix may be "", for modules that are imported without prefix.
/// See [NonPrefixedImportScope].
class ImportScope : public IterableScope {
 public:
  explicit ImportScope(Symbol prefix) : prefix_(prefix) { }

  void add(ModuleScope* scope, bool is_explicitly_imported) {
    imported_scopes_.insert(scope);
    // If a scope is imported both implicitly and explicitly, the explicit
    //   import wins.
    if (is_explicitly_imported) explicitly_imported_.insert(scope);
  }

  /// Looks up the corresponding name in the modules.
  virtual ResolutionEntry lookup(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    return lookup(name, false, already_visited);
  }

  /// Looks up the corresponding name in the modules, but skips implicitly imported modules.
  virtual ResolutionEntry lookup_external(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    return lookup(name, true, already_visited);
  }

  /// Invokes the given [callback] on each declaration of this prefix.
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    UnorderedSet<ModuleScope*> already_visited;
    for_each(callback, &already_visited);
  }

  /// Invokes the given [callback] on each declaration of this prefix, but
  ///   skips implicitly imported modules.
  void for_each_external(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    UnorderedSet<ModuleScope*> already_visited;
    for_each_external(callback, &already_visited);
  }

  virtual void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                        UnorderedSet<ModuleScope*>* already_visited) {
    for_each(callback, false, already_visited);
  }

  virtual void for_each_external(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                                 UnorderedSet<ModuleScope*>* already_visited) {
    for_each(callback, true, already_visited);
  }

  Symbol prefix() const { return prefix_; }

  Set<ModuleScope*> imported_scopes() const {
    return imported_scopes_;
  }

  bool is_prefixed_scope() const {
    return prefix_.is_valid() && prefix_.c_str()[0] != '\0';
  }

 private:
  Symbol prefix_;
  Set<ModuleScope*> imported_scopes_;
  Set<ModuleScope*> explicitly_imported_;

  Scope::ResolutionEntryMap cache_;
  Scope::ResolutionEntryMap cache_external_;

  /// Looks up the corresponding name in the modules.
  ResolutionEntry lookup(Symbol name,
                         bool is_external_lookup,
                         UnorderedSet<ModuleScope*>* already_visited);

  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                bool is_external_for_each,
                UnorderedSet<ModuleScope*>* already_visited);
};

/// Non-prefixed imports.
///
/// This scope includes:
///   - modules that are imported relatively, and modules that are imported
///       with `show *`
///   - declarations that are explicitly shown: `show X`.
///   - all [ImportScope]s of modules that have been imported with a prefix.
class NonPrefixedImportScope : public ImportScope {
 public:
  NonPrefixedImportScope() : ImportScope(Symbols::empty_string) { }

  void add(ModuleScope* scope, bool is_explicitly_imported) {
    ImportScope::add(scope, is_explicitly_imported);
  }

  void add(Symbol name, const ResolutionEntry& entry) {
    prefixes_and_explicit_[name] = entry;
  }

  /// Looks up the corresponding name in the prefixes and imported modules.
  ///
  /// Prefixes (in case `this` is the ""-prefix) and explicit entries (`show`)
  ///   are looked up first and shadow other imported declarations.
  ResolutionEntry lookup(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    // Try the prefixes and explicit entries first, since they
    // shadow imported identifiers.
    auto probe = prefixes_and_explicit_.find(name);
    if (probe != prefixes_and_explicit_.end()) return probe->second;

    return ImportScope::lookup(name, already_visited);
  }

  /// Same as `lookup` but does not visit implicitly imported modules, as
  ///   they are not transitively exported.
  ResolutionEntry lookup_external(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    // Try the prefixes and explicit entries first, since they
    // shadow imported identifiers.
    auto probe = prefixes_and_explicit_.find(name);
    if (probe != prefixes_and_explicit_.end()) return probe->second;

    return ImportScope::lookup_external(name, already_visited);
  }

  /// Invokes the given [callback] on each prefix and imported declaration.
  ///
  /// First invokes [callback] on prefixes, and `show` identifiers.
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                UnorderedSet<ModuleScope*>* already_visited) {
    prefixes_and_explicit_.for_each(callback);
    ImportScope::for_each(callback, already_visited);
  }

  /// Invokes the given [callback] on imported declaration.
  ///
  /// Skips implicitly imported modules.
  /// First invokes [callback] on prefixes, and `show` identifiers.
  void for_each_external(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                         UnorderedSet<ModuleScope*>* already_visited) {
    prefixes_and_explicit_.for_each(callback);
    ImportScope::for_each_external(callback, already_visited);
  }

  /// Looks up the corresponding name in the prefixes and `show` declarations.
  ///
  /// Does not search the [name] in other imported declarations.
  ResolutionEntry lookup_prefix_and_explicit(Symbol name) {
    auto probe = prefixes_and_explicit_.find(name);
    if (probe == prefixes_and_explicit_.end()) return ResolutionEntry();
    return probe->second;
  }

 private:
  Scope::ResolutionEntryMap prefixes_and_explicit_;
};

/// The top-level scope of a module.
///
/// Contains all top-level entries, and all imported declarations.
///
/// Supports "module_" lookups that only consider non-imported declarations.
class ModuleScope : public Scope {
 public:
  ModuleScope(Module* module,
              bool export_all)
      : Scope(null)
      , module_(module)
      , non_prefixed_imported_(null)
      , export_all_(export_all) { }

  void add(Symbol name, ResolutionEntry entry) {
    ASSERT(!contains_local(name));
    module_declarations_[name] = entry;
  }

  /// Searches in the module declarations *and* all imported declarations.
  ///
  /// Finds:
  ///   - toplevel declarations of this module
  ///   - prefixes
  ///   - toplevel declarations of modules that have been imported without prefix
  ///   - `export`ed declarations of modules that have been imported without prefix
  ///   - `show` declarations of imported modules
  ResolutionEntry lookup_shallow(Symbol name) {
    auto probe = module_declarations_.find(name);
    if (probe != module_declarations_.end()) return probe->second;

    UnorderedSet<ModuleScope*> already_visited;
    return non_prefixed_imported_->lookup(name, &already_visited);
  }

  /// Invokes callback for all declarations that could be found with `lookup_shallow`.
  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    module_declarations_.for_each(callback);

    UnorderedSet<ModuleScope*> already_visited;
    non_prefixed_imported_->for_each(callback, &already_visited);
  }

  /// Only searches in the non-transitive identifiers of the module.
  /// This does not include prefixes.
  ResolutionEntry lookup_module(Symbol name) {
    auto probe = module_declarations_.find(name);
    if (probe != module_declarations_.end()) return probe->second;
    return ResolutionEntry();
  }

  /// Searches in all declarations that are exported, implicitly or explicitly, from
  ///   this module:
  ///     - each declaration in the module
  ///     - each exported declaration (through `export X` or `export *`).
  /// The [being_looked_at] set keeps track of modules that are being
  /// looked up when hunting down exports.
  /// Otherwise we could end up in infinite loops.
  ResolutionEntry lookup_external(Symbol name,
                                  UnorderedSet<ModuleScope*>* already_visited);

  /// Invokes callback for each declaration that could be found via `lookup_external`.
  ///
  /// Also invokes the callback on shadowed declarations. That is, the function does not
  ///   keep track of which identifiers have already been seen.
  void for_each_external(const std::function<void (Symbol,
                                                   const ResolutionEntry&)>& callback,
                                                   UnorderedSet<ModuleScope*>* already_visited);

  Module* module() const { return module_; }

  ClassScope* enclosing_class_scope() { return null; }
  ModuleScope* module_scope() { return this; }

  // All the imports that are reachable without prefix.
  void set_non_prefixed_imported(NonPrefixedImportScope* modules) {
    non_prefixed_imported_ = modules;
  }
  NonPrefixedImportScope* non_prefixed_imported() const { return non_prefixed_imported_; }

  ResolutionEntryMap entries() const { return module_declarations_; }

  bool exported_identifiers_map_has_been_set() const { return exported_identifiers_map_has_been_set_; }
  ResolutionEntryMap exported_identifiers_map() const { return exported_identifiers_map_; }

  void set_exported_identifiers_map(ResolutionEntryMap exported_identifiers_map) {
    exported_identifiers_map_ = exported_identifiers_map;
    exported_identifiers_map_has_been_set_ = true;
  }

 private:
  Module* module_;
  NonPrefixedImportScope* non_prefixed_imported_;
  bool export_all_;
  bool exported_identifiers_map_has_been_set_ = false;
  ResolutionEntryMap exported_identifiers_map_;

  ResolutionEntryMap module_declarations_;

  /// Whether this module has a (non-imported) top-level declaration of the
  /// given name.
  bool contains_local(Symbol name) {
    return module_declarations_.find(name) != module_declarations_.end();
  }
};

class SimpleScope : public Scope {
 public:
  using Scope::Scope;  // Inherit constructor.

  void add(Symbol name, ResolutionEntry entry) {
    // We would like to check that the name isn't in the dictionary yet.
    // However, we continue analysis even after we detected duplicated names,
    // in which case an assert would trigger.
    dictionary_[name] = entry;
  }

  ResolutionEntry lookup_shallow(Symbol name) {
    auto probe = dictionary_.find(name);
    if (probe == dictionary_.end()) {
      return ResolutionEntry();
    } else {
      return probe->second;
    }
  }

  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    dictionary_.for_each(callback);
  }

  ClassScope* enclosing_class_scope() { return outer()->enclosing_class_scope(); }

 protected:
  ResolutionEntryMap dictionary() { return dictionary_; }

 private:
  ResolutionEntryMap dictionary_;
};

/// The scope inside a class.
///
/// Includes fields, and super-class members which shadow top-level elements.
class ClassScope : public SimpleScope {
 public:
  explicit ClassScope(ir::Class* klass, Scope* outer) : SimpleScope(outer), class_(klass) {
    ASSERT(outer != null);
  }

  static constexpr ir::Node* SUPER_CLASS_SEPARATOR = null;

  ResolutionEntryMap declarations() { return dictionary(); }

  ClassScope* enclosing_class_scope() { return this; }

  ir::Class* klass() const { return class_; }

 private:
  ir::Class* class_;
};

/// A scope within a method (or initializer).
class LocalScope : public SimpleScope {
 public:
  explicit LocalScope(Scope* outer) : SimpleScope(outer) {
    ASSERT(outer != null);
  }
};

/// A local scope that increases the block level for each lookup.
class BlockScope : public SimpleScope {
 public:
  explicit BlockScope(Scope* outer) : SimpleScope(outer) {
    ASSERT(outer != null);
  }

  LookupResult lookup(Symbol name) {
    auto entry = lookup_shallow(name);
    if (!entry.is_empty()) {
      return {
        .entry = entry,
        .block_depth = 0
      };
    }
    auto outer_result = outer()->lookup(name);
    if (outer_result.entry.is_empty()) return outer_result;
    return {
      .entry = outer_result.entry,
      .block_depth = outer_result.block_depth + 1
    };
  }
};

/// A scope that collects captured variables.
class LambdaScope : public SimpleScope {
 public:
  explicit LambdaScope(Scope* outer) : SimpleScope(outer) {
    ASSERT(outer != null);
  }

  LookupResult lookup(Symbol name) {
    auto entry = lookup_shallow(name);
    if (!entry.is_empty()) {
      return {
        .entry = entry,
        .block_depth = 0
      };
    }
    auto outer_result = outer()->lookup(name);
    // A local must be a node.
    if (outer_result.entry.kind() != ResolutionEntry::NODES) return outer_result;
    // Locals are always single.
    // If there are more nodes, than it must be an overloaded function.
    if (outer_result.entry.nodes().length() != 1) return outer_result;

    auto single = outer_result.entry.single();
    if (single->is_Local()) {
      captured_depths_[single->as_Local()] = outer_result.block_depth;
    }

    return  outer_result;
  }

  Map<ir::Local*, int> captured_depths() const { return captured_depths_; }

 private:
  Map<ir::Local*, int> captured_depths_;
};

/// A scope that adds the `it` parameter, and keeps track of whether the parameter was used.
class ItScope : public Scope {
 public:
  explicit ItScope(Scope* outer)
      : Scope(outer), it_(null), it_was_used_(false) { }

  void add(Symbol name, ResolutionEntry entry) { outer()->add(name, entry); }

  ResolutionEntry lookup_shallow(Symbol name) {
    if (name == it_->name()) {
      it_was_used_ = true;
      return ResolutionEntry(it_);
    }
    return ResolutionEntry();
  }

  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    ASSERT(it_ != null);
    callback(it_->name(), ResolutionEntry(it_));
  }

  ClassScope* enclosing_class_scope() { return outer()->enclosing_class_scope(); }

  ir::Parameter* it() const { return it_; }
  void set_it(ir::Parameter* it) { it_ = it; }

  bool it_was_used() const { return it_was_used_; }

 private:
  ir::Parameter* it_;
  bool it_was_used_;
};

class ScopeFiller {
 public:
  explicit ScopeFiller(bool discard_invalid_symbols = false)
      : discard_invalid_(discard_invalid_symbols) { }

  void add(Symbol name, ir::Node* node) {
    if (!name.is_valid() && discard_invalid_) return;
    declarations_[name].push_back(node);
  }

  template<typename T> void add_all(T ir_list) {
    for (auto ir_node : ir_list) {
      add(ir_node->name(), ir_node);
    }
  }

  template<typename S> void fill(S scope) {
    for (auto name : declarations_.keys()) {
      auto& vector = declarations_[name];
      auto list = ListBuilder<ir::Node*>::build_from_vector(vector);
      scope->add(name, ResolutionEntry(list));
    }
  }

 private:
  bool discard_invalid_;
  Map<Symbol, std::vector<ir::Node*>> declarations_;
};

} // namespace toit::compiler
} // namespace toit

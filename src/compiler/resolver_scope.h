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
      : _unit(unit)
      , _classes(classes)
      , _methods(methods)
      , _globals(globals)
      , _export_all(export_all)
      , _exported_identifiers(exported_identifiers)
      , _scope(null) { }

  ast::Unit* unit() const { return _unit; }

  List<ir::Class*> classes() const { return _classes; }
  List<ir::Method*> methods() const { return _methods; }
  List<ir::Global*> globals() const { return _globals; }

  // Imported modules are not exported. They may have a prefix.
  //
  // The returned list is sorted, so that modules without prefix are first.
  List<PrefixedModule> imported_modules() const { return _imported_modules; }
  void set_imported_modules(List<PrefixedModule> modules) {
    ASSERT(_non_prefixed_are_first(modules));
    _imported_modules = modules;
  }

  bool export_all() const { return _export_all; }
  Set<Symbol> exported_identifiers() const { return _exported_identifiers; }

  ModuleScope* scope() const { return _scope; }
  void set_scope(ModuleScope* scope) { _scope = scope; }

  bool is_error_module() const { return _unit->is_error_unit(); }

  void add_first_segment_prefix(Symbol first_segment_prefix, Symbol last_segment_prefix, const Source::Range& range) {
    _first_segment_prefixes[first_segment_prefix].push_back(std::make_pair(last_segment_prefix, range));
  }

  bool is_first_segment_prefix(Symbol symbol) {
    return _first_segment_prefixes.find(symbol) != _first_segment_prefixes.end();
  }
  std::vector<std::pair<Symbol, Source::Range>> first_segment_prefixes_for(Symbol symbol) {
    return _first_segment_prefixes.at(symbol);
  }
  bool has_first_segment_prefixes() const { return !_first_segment_prefixes.empty(); }
  void mark_reported_deprecation(const Source::Range& range) { _reported_first_segment_warnings.insert(range); }
  bool needs_first_segment_deprecation_warning(const Source::Range& range) {
    return !_reported_first_segment_warnings.contains(range);
  }

 private:
  ast::Unit* _unit;
  List<ir::Class*> _classes;
  List<ir::Method*> _methods;
  List<ir::Global*> _globals;

  /// Support for deprecated use-of-first-segment-as-import-prefix.
  Map<Symbol, std::vector<std::pair<Symbol, Source::Range>>> _first_segment_prefixes;
  UnorderedSet<Source::Range> _reported_first_segment_warnings;

  List<PrefixedModule> _imported_modules;
  bool _export_all;
  Set<Symbol> _exported_identifiers;

  ModuleScope* _scope;

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

  ResolutionEntry() : _kind(NODES), _nodes(List<ir::Node*>()) { }
  explicit ResolutionEntry(List<ir::Node*> nodes)
      : _kind(NODES), _nodes(nodes) { }
  explicit ResolutionEntry(ir::Node* node)
      : _kind(NODES), _nodes(ListBuilder<ir::Node*>::build(node)) { }

  explicit ResolutionEntry(ImportScope* prefix) : _kind(PREFIX), _prefix(prefix) { }

  // Used for ambiguous nodes.
  explicit ResolutionEntry(Kind kind) : _kind(kind), _nodes(List<ir::Node*>()) { }

  Kind kind() const { return _kind; }

  List<ir::Node*> nodes() const {
    ASSERT(_kind == NODES || _kind == AMBIGUOUS);
    return _nodes;
  }
  void set_nodes(List<ir::Node*> nodes) {
    ASSERT(_kind == NODES || _kind == AMBIGUOUS);
    _nodes = nodes;
  }

  bool is_empty() const {
    return _kind == NODES && _nodes.is_empty();
  }

  bool is_class() const {
    return _kind == NODES &&
        _nodes.length() == 1 &&
        (_nodes[0]->is_Class() || _nodes[0]->is_Constructor());
  }

  ir::Class* klass() const {
    ASSERT(is_class());
    if (_nodes[0]->is_Class()) return _nodes[0]->as_Class();
    return _nodes[0]->as_Constructor()->klass();
  }

  bool is_single() const { return _kind == NODES && _nodes.length() == 1; }
  ir::Node* single() const {
    ASSERT(is_single());
    return _nodes[0];
  }

  bool is_prefix() const { return _kind == PREFIX; }

  ImportScope* prefix() const {
    ASSERT(_kind == PREFIX);
    return _prefix;
  }

 private:
  Kind _kind;
  union {
    List<ir::Node*> _nodes;
    ImportScope* _prefix;
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
      : _wrapped(wrapped)
      , _predicate(predicate) { }

  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    _wrapped->for_each([&] (Symbol symbol, const ResolutionEntry& entry) {
      if (_predicate(symbol, entry)) callback(symbol, entry);
    });
  }

 private:
  IterableScope* _wrapped;
  std::function<bool (Symbol, const ResolutionEntry&)> _predicate;
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

  explicit Scope(Scope* outer) : _outer(outer) { }

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

  Scope* outer() const { return _outer; }

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
  Scope* _outer;

  ImportScope* _find_import_scope(ast::Node* node);

  ast::Node* _find_import_scope_node_cache = null;
  ImportScope* _find_import_scope_result_cache = null;
  ast::Node* _lookup_static_node_cache = null;
  ResolutionEntry _lookup_static_result_cache;
  ast::Node* _lookup_prefix_node_cache = null;
  ResolutionEntry _lookup_prefix_result_cache;
};

/// A scope (but not implementing the `Scope` interface) for static declarations
///   inside a class.
/// Toplevel statics are handled in ModuleScopes.
class StaticsScope : public IterableScope {
 public:
  StaticsScope() : _map_is_valid(true) { }

  void add(Symbol name, const ResolutionEntry& entry) {
    ASSERT(_map_is_valid);
    _entries[name] = entry;
    for (auto node : entry.nodes()) {
      ASSERT(node->is_Method());
      _nodes.push_back(node->as_Method());
    }
  }

  /// Looks up the corresponding name in the prefixes and imported modules.
  ResolutionEntry lookup(Symbol name) {
    ASSERT(_map_is_valid);
    auto probe = _entries.find(name);
    if (probe != _entries.end()) return probe->second;
    return ResolutionEntry();
  }

  /// Invokes the given [callback] on each entry that could be found via [lookup].
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    ASSERT(_map_is_valid);
    _entries.for_each(callback);
  }

  std::vector<ir::Method*> nodes() const { return _nodes; }
  void replace_nodes(const std::vector<ir::Method*>& new_nodes) {
    ASSERT(!_map_is_valid);
    _nodes = new_nodes;
  }

  void invalidate_resolution_map() {
    _entries.clear();
    _map_is_valid = false;
  }

  Scope::ResolutionEntryMap entries() const { return _entries; }

  bool is_prefixed_scope() const { return true; }

 private:
  bool _map_is_valid;
  Scope::ResolutionEntryMap _entries;
  // The nodes are redundant (since they are already in the _entries map), but
  // this simplifies the code a lot.
  std::vector<ir::Method*> _nodes;
};

/// One or more imported modules with the same prefix.
///
/// The prefix may be "", for modules that are imported without prefix.
/// See [NonPrefixedImportScope].
class ImportScope : public IterableScope {
 public:
  explicit ImportScope(Symbol prefix) : _prefix(prefix) { }

  void add(ModuleScope* scope, bool is_explicitly_imported) {
    _imported_scopes.insert(scope);
    // If a scope is imported both implicitly and explicitly, the explicit
    //   import wins.
    if (is_explicitly_imported) _explicitly_imported.insert(scope);
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

  Symbol prefix() const { return _prefix; }

  Set<ModuleScope*> imported_scopes() const {
    return _imported_scopes;
  }

  bool is_prefixed_scope() const {
    return _prefix.is_valid() && _prefix.c_str()[0] != '\0';
  }

 private:
  Symbol _prefix;
  Set<ModuleScope*> _imported_scopes;
  Set<ModuleScope*> _explicitly_imported;

  Scope::ResolutionEntryMap _cache;
  Scope::ResolutionEntryMap _cache_external;

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
    _prefixes_and_explicit[name] = entry;
  }

  /// Looks up the corresponding name in the prefixes and imported modules.
  ///
  /// Prefixes (in case `this` is the ""-prefix) and explicit entries (`show`)
  ///   are looked up first and shadow other imported declarations.
  ResolutionEntry lookup(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    // Try the prefixes and explicit entries first, since they
    // shadow imported identifiers.
    auto probe = _prefixes_and_explicit.find(name);
    if (probe != _prefixes_and_explicit.end()) return probe->second;

    return ImportScope::lookup(name, already_visited);
  }

  /// Same as `lookup` but does not visit implicitly imported modules, as
  ///   they are not transitively exported.
  ResolutionEntry lookup_external(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    // Try the prefixes and explicit entries first, since they
    // shadow imported identifiers.
    auto probe = _prefixes_and_explicit.find(name);
    if (probe != _prefixes_and_explicit.end()) return probe->second;

    return ImportScope::lookup_external(name, already_visited);
  }

  /// Invokes the given [callback] on each prefix and imported declaration.
  ///
  /// First invokes [callback] on prefixes, and `show` identifiers.
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                UnorderedSet<ModuleScope*>* already_visited) {
    _prefixes_and_explicit.for_each(callback);
    ImportScope::for_each(callback, already_visited);
  }

  /// Invokes the given [callback] on imported declaration.
  ///
  /// Skips implicitly imported modules.
  /// First invokes [callback] on prefixes, and `show` identifiers.
  void for_each_external(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                         UnorderedSet<ModuleScope*>* already_visited) {
    _prefixes_and_explicit.for_each(callback);
    ImportScope::for_each_external(callback, already_visited);
  }

  /// Looks up the corresponding name in the prefixes and `show` declarations.
  ///
  /// Does not search the [name] in other imported declarations.
  ResolutionEntry lookup_prefix_and_explicit(Symbol name) {
    auto probe = _prefixes_and_explicit.find(name);
    if (probe == _prefixes_and_explicit.end()) return ResolutionEntry();
    return probe->second;
  }

 private:
  Scope::ResolutionEntryMap _prefixes_and_explicit;
};

/// The top-level scope of a module.
///
/// Contains all top-level entries, and all imported declarations.
///
/// Supports "_module" lookups that only consider non-imported declarations.
class ModuleScope : public Scope {
 public:
  ModuleScope(Module* module,
              bool export_all)
      : Scope(null)
      , _module(module)
      , _non_prefixed_imported(null)
      , _export_all(export_all) { }

  void add(Symbol name, ResolutionEntry entry) {
    ASSERT(!contains_local(name));
    _module_declarations[name] = entry;
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
    auto probe = _module_declarations.find(name);
    if (probe != _module_declarations.end()) return probe->second;

    UnorderedSet<ModuleScope*> already_visited;
    return _non_prefixed_imported->lookup(name, &already_visited);
  }

  /// Invokes callback for all declarations that could be found with `lookup_shallow`.
  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    _module_declarations.for_each(callback);

    UnorderedSet<ModuleScope*> already_visited;
    _non_prefixed_imported->for_each(callback, &already_visited);
  }

  /// Only searches in the non-transitive identifiers of the module.
  /// This does not include prefixes.
  ResolutionEntry lookup_module(Symbol name) {
    auto probe = _module_declarations.find(name);
    if (probe != _module_declarations.end()) return probe->second;
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

  Module* module() const { return _module; }

  ClassScope* enclosing_class_scope() { return null; }
  ModuleScope* module_scope() { return this; }

  // All the imports that are reachable without prefix.
  void set_non_prefixed_imported(NonPrefixedImportScope* modules) {
    _non_prefixed_imported = modules;
  }
  NonPrefixedImportScope* non_prefixed_imported() const { return _non_prefixed_imported; }

  ResolutionEntryMap entries() const { return _module_declarations; }

  bool exported_identifiers_map_has_been_set() const { return _exported_identifiers_map_has_been_set; }
  ResolutionEntryMap exported_identifiers_map() const { return _exported_identifiers_map; }

  void set_exported_identifiers_map(ResolutionEntryMap exported_identifiers_map) {
    _exported_identifiers_map = exported_identifiers_map;
    _exported_identifiers_map_has_been_set = true;
  }

 private:
  Module* _module;
  NonPrefixedImportScope* _non_prefixed_imported;
  bool _export_all;
  bool _exported_identifiers_map_has_been_set = false;
  ResolutionEntryMap _exported_identifiers_map;

  ResolutionEntryMap _module_declarations;

  /// Whether this module has a (non-imported) top-level declaration of the
  /// given name.
  bool contains_local(Symbol name) {
    return _module_declarations.find(name) != _module_declarations.end();
  }
};

class SimpleScope : public Scope {
 public:
  using Scope::Scope;  // Inherit constructor.

  void add(Symbol name, ResolutionEntry entry) {
    // We would like to check that the name isn't in the dictionary yet.
    // However, we continue analysis even after we detected duplicated names,
    // in which case an assert would trigger.
    _dictionary[name] = entry;
  }

  ResolutionEntry lookup_shallow(Symbol name) {
    auto probe = _dictionary.find(name);
    if (probe == _dictionary.end()) {
      return ResolutionEntry();
    } else {
      return probe->second;
    }
  }

  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    _dictionary.for_each(callback);
  }

  ClassScope* enclosing_class_scope() { return outer()->enclosing_class_scope(); }

 protected:
  ResolutionEntryMap dictionary() { return _dictionary; }

 private:
  ResolutionEntryMap _dictionary;
};

/// The scope inside a class.
///
/// Includes fields, and super-class members which shadow top-level elements.
class ClassScope : public SimpleScope {
 public:
  explicit ClassScope(ir::Class* klass, Scope* outer) : SimpleScope(outer), _class(klass) {
    ASSERT(outer != null);
  }

  static constexpr ir::Node* SUPER_CLASS_SEPARATOR = null;

  ResolutionEntryMap declarations() { return dictionary(); }

  ClassScope* enclosing_class_scope() { return this; }

  ir::Class* klass() const { return _class; }

 private:
  ir::Class* _class;
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
      _captured_depths[single->as_Local()] = outer_result.block_depth;
    }

    return  outer_result;
  }

  Map<ir::Local*, int> captured_depths() const { return _captured_depths; }

 private:
  Map<ir::Local*, int> _captured_depths;
};

/// A scope that adds the `it` parameter, and keeps track of whether the parameter was used.
class ItScope : public Scope {
 public:
  explicit ItScope(Scope* outer)
      : Scope(outer), _it(null), _it_was_used(false) { }

  void add(Symbol name, ResolutionEntry entry) { outer()->add(name, entry); }

  ResolutionEntry lookup_shallow(Symbol name) {
    if (name == _it->name()) {
      _it_was_used = true;
      return ResolutionEntry(_it);
    }
    return ResolutionEntry();
  }

  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    ASSERT(_it != null);
    callback(_it->name(), ResolutionEntry(_it));
  }

  ClassScope* enclosing_class_scope() { return outer()->enclosing_class_scope(); }

  ir::Parameter* it() const { return _it; }
  void set_it(ir::Parameter* it) { _it = it; }

  bool it_was_used() const { return _it_was_used; }

 private:
  ir::Parameter* _it;
  bool _it_was_used;
};

class ScopeFiller {
 public:
  explicit ScopeFiller(bool discard_invalid_symbols = false)
      : _discard_invalid(discard_invalid_symbols) { }

  void add(Symbol name, ir::Node* node) {
    if (!name.is_valid() && _discard_invalid) return;
    _declarations[name].push_back(node);
  }

  template<typename T> void add_all(T ir_list) {
    for (auto ir_node : ir_list) {
      add(ir_node->name(), ir_node);
    }
  }

  template<typename S> void fill(S scope) {
    for (auto name : _declarations.keys()) {
      auto& vector = _declarations[name];
      auto list = ListBuilder<ir::Node*>::build_from_vector(vector);
      scope->add(name, ResolutionEntry(list));
    }
  }

 private:
  bool _discard_invalid;
  Map<Symbol, std::vector<ir::Node*>> _declarations;
};

/// Support for deprecated use-of-first-segment-as-import-prefix.
class FirstSegmentPrefixCompatibilityModuleScope : public Scope {
 public:
  FirstSegmentPrefixCompatibilityModuleScope(ModuleScope* wrapped, Module* module, Diagnostics* diagnostics)
      : Scope(null)
      , _wrapped(wrapped)
      , _module(module)
      , _diagnostics(diagnostics) { }

  ResolutionEntry lookup_shallow(Symbol name);

  void add(Symbol name, ResolutionEntry entry) { UNREACHABLE(); }
  // 'for_each' is only used for completion. We can thus just use the _wrapped
  // scope.
  void for_each_shallow(const std::function<void (Symbol, const ResolutionEntry&)>& callback) {
    _wrapped->for_each_shallow(callback);
  }
  ClassScope* enclosing_class_scope() { return _wrapped->enclosing_class_scope(); }

 private:
  ModuleScope* _wrapped;
  Module* _module;
  Diagnostics* _diagnostics;

  Map<Symbol, ResolutionEntry> _import_scope_cache;
};

/// Support for deprecated use-of-first-segment-as-import-prefix.
class FirstSegmentCompatibilityImportScope : public ImportScope {
 public:
  FirstSegmentCompatibilityImportScope(Symbol prefix,
                        ImportScope* existing,
                        const std::vector<std::pair<ImportScope*, Source::Range>>& deprecated,
                        Module* module,
                        Diagnostics* diagnostics)
      : ImportScope(prefix)
      , _last_segment(existing)
      , _first_segments(deprecated)
      , _module(module)
      , _diagnostics(diagnostics) { }


  /// Looks up the corresponding name in the modules.
  ResolutionEntry lookup(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    return do_all([&] (ImportScope* scope) {
      return scope->lookup(name, already_visited);
    });
  }

  /// Looks up the corresponding name in the modules, but skips implicitly imported modules.
  ResolutionEntry lookup_external(Symbol name, UnorderedSet<ModuleScope*>* already_visited) {
    return do_all([&] (ImportScope* scope) {
      return scope->lookup_external(name, already_visited);
    });
  }


  // `for_each` is only used for LSP, in which case we can only show the existing ones.
  void for_each(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                UnorderedSet<ModuleScope*>* already_visited) {
    if (_last_segment != null) {
      _last_segment->for_each(callback, already_visited);
    }
  }

  // `for_each` is only used for LSP, in which case we can only show the existing ones.
  void for_each_external(const std::function<void (Symbol, const ResolutionEntry&)>& callback,
                         UnorderedSet<ModuleScope*>* already_visited)  {
    if (_last_segment != null) {
      _last_segment->for_each_external(callback, already_visited);
    }
  }

 private:
  ImportScope* _last_segment;
  std::vector<std::pair<ImportScope*, Source::Range>> _first_segments;
  Module* _module;
  Diagnostics* _diagnostics;

  ResolutionEntry do_all(const std::function<ResolutionEntry (ImportScope* scope)> fun);
};

} // namespace toit::compiler
} // namespace toit

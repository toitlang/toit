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

#include <vector>
#include <functional>

#include "ast.h"
#include "ir.h"
#include "list.h"
#include "map.h"
#include "parser.h"
#include "set.h"
#include "sources.h"
#include "toitdoc.h"


namespace toit {
namespace compiler {

class Diagnostics;
class Scope;
class Lsp;
class ToplevelScope;
class Module;
class ModuleScope;

class Resolver {
 public:
  Resolver(Lsp* lsp,
           SourceManager* source_manager,
           Diagnostics* diagnostics,
           ToitdocRegistry* toitdocs)
      : source_manager_(source_manager)
      , diagnostics_(diagnostics)
      , lsp_(lsp)
      , toitdocs_(toitdocs) {}

  ir::Program* resolve(const std::vector<ast::Unit*>& units,
                       int entry_unit_index,
                       int core_unit_index);

  ToitdocRegistry* toitdocs() { return toitdocs_; }

  /// Maps IR nodes to their originating AST nodes.
  ///
  /// During resolution, most AST source-range information is discarded
  /// as IR nodes record only essential positional data.  This map
  /// preserves the AST nodes for the small set of cases where the
  /// rename/reference visitor needs source ranges that the IR does not
  /// carry — for example:
  ///  - setter CallVirtual → AST Dot (to recover the property name range),
  ///  - Typecheck → AST type expression (to recover the class-name range
  ///    inside a type annotation like `x/Foo`),
  ///  - Call with named arguments → AST Call (to recover the `--param`
  ///    source range for named-argument rename),
  ///  - field-storing parameters → AST field (to map constructors
  ///    parameter back to the field declaration).
  ///
  /// Entries are inserted in resolver_method.cc at the point where each
  /// IR node is created from its AST counterpart.  The map is then
  /// moved into the rename pipeline (FindReferencesPipeline) before the
  /// resolver is destroyed, so the visitor can look up AST ranges during
  /// its IR traversal.
  UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map() { return ir_to_ast_map_; }

  /// A reference from a show/export clause to a resolved definition.
  ///
  /// During resolution, each `import ... show Foo` and `export Foo`
  /// clause resolves the identifier to an ir::Node* target. We collect
  /// these mappings so that the rename pipeline can find show/export
  /// references to a given definition without needing access to the
  /// module infrastructure (which is local to the resolver).
  struct ShowExportReference {
    ir::Node* target;       // The resolved definition (e.g., ir::Class*).
    Source::Range range;     // The source range of the identifier in the show/export clause.
  };

  /// Returns all show/export references collected during resolution.
  const std::vector<ShowExportReference>& show_export_references() const {
    return show_export_references_;
  }

  /// A resolved reference from an `implements` or `with` clause.
  ///
  /// During resolution, each AST expression in a class's `implements` or
  /// `with` clause is resolved to an `ir::Class*`.  We record these
  /// mappings before the resolver's flattening passes (`flatten_mixins`
  /// and `check_interface_implementations_and_flatten`) replace the IR
  /// interface/mixin lists with their transitive closures.  After
  /// flattening, positional correspondence between the IR and AST lists
  /// is lost, so the rename pipeline needs this explicit mapping to find
  /// the source-level expressions for a given IR class.
  struct ClassHierarchyReference {
    ir::Class* holder;       // The class containing the implements/with clause.
    ir::Class* target;       // The resolved interface or mixin.
    ast::Expression* ast_node;  // The AST expression in the clause.
  };

  /// Returns all class hierarchy references collected during resolution.
  const std::vector<ClassHierarchyReference>& class_hierarchy_references() const {
    return class_hierarchy_references_;
  }

 private:
  SourceManager* source_manager_;
  Diagnostics* diagnostics_;
  Lsp* lsp_;
  ToitdocRegistry* toitdocs_;
  UnorderedMap<ir::Node*, ast::Node*> ir_to_ast_map_;
  std::vector<ir::AssignmentGlobal*> global_assignments_;
  std::vector<ShowExportReference> show_export_references_;
  std::vector<ClassHierarchyReference> class_hierarchy_references_;

  Diagnostics* diagnostics() const { return diagnostics_; }

  void report_error(const ast::Node* position_node, const char* format, ...);
  void report_error(ir::Node* position_node, const char* format, ...);
  void report_error(const char* format, ...);
  void report_note(const ast::Node* position_node, const char* format, ...);
  void report_note(ir::Node* position_node, const char* format, ...);
  void report_warning(const ast::Node* position_node, const char* format, ...);
  void report_warning(ir::Node* position_node, const char* format, ...);

  ast::Class* ast_for(ir::Class* node) { return ir_to_ast_map_.at(node)->as_Class(); }
  ast::Method* ast_for(ir::Method* node) { return ir_to_ast_map_.at(node)->as_Method(); }

  std::vector<Module*> build_modules(const std::vector<ast::Unit*>& units,
                                     int entry_unit_index,
                                     int core_unit_index);
  void resolve_shows_and_exports(std::vector<Module*>& modules);
  void build_module_scopes(std::vector<Module*>& modules);

  void check_clashing_or_conflicting(Symbol name, List<ir::Node*> declarations);
  void check_clashing_or_conflicting(std::vector<Module*> modules);
  void check_future_reserved_globals(std::vector<Module*> modules);

  void mark_runtime(Module* core_module);
  void mark_non_returning(Module* core_module);

  void setup_inheritance(std::vector<Module*> modules, int core_module_index);
  void report_abstract_classes(std::vector<Module*> modules);
  void check_interface_implementations_and_flatten(std::vector<Module*> modules);
  void flatten_mixins(std::vector<Module*> modules);
  List<ir::Class*> find_tree_roots(Module* core_module);
  List<ir::Method*> find_entry_points(Module* core_module);
  List<ir::Type> find_literal_types(Module* core_module);
  ir::Constructor* build_default_constructor(ir::Class* klass, bool* detected_error);
  void check_method(ast::Method* method, ir::Class* holder,
                    Symbol* name, ir::Method::MethodKind* kind,
                    bool allow_future_reserved);
  void check_field(ast::Field* method, ir::Class* holder);
  void check_class(ast::Class* klass);
  void fill_classes_with_skeletons(std::vector<Module*> modules);
  void resolve_fill_module(Module* module,
                           Module* entry_module,
                           Module* core_module);
  void resolve_fill_toplevel_methods(Module* module,
                                     Module* entry_module,
                                     Module* core_module);
  void resolve_fill_classes(Module* module,
                            Module* entry_module,
                            Module* core_module);
  void resolve_fill_class(ir::Class* klass,
                          ModuleScope* module_scope,
                          Module* entry_module,
                          Module* core_module);
  void resolve_fill_globals(Module* module,
                            Module* entry_module,
                            Module* core_module);
  void resolve_fill_method(ir::Method* method,
                           ir::Class* holder,
                           Scope* scope,
                           Module* entry_module,
                           Module* core_module);
  void resolve_field(ir::Field* field,
                     ir::Class* holder,
                     Scope* scope,
                     Module* entry_module,
                     Module* core_module);
  ir::Class* resolve_class_interface_or_mixin(ast::Expression* ast_node,
                                              Scope* scope,
                                              ir::Class* holder,
                                              bool needs_class,
                                              bool needs_mixin);

  void add_global_assignment_typechecks();
};

} // namespace toit::compiler
} // namespace toit

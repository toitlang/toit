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
           Diagnostics* diagnostics)
      : source_manager_(source_manager)
      , diagnostics_(diagnostics)
      , lsp_(lsp) {}

  ir::Program* resolve(const std::vector<ast::Unit*>& units,
                       int entry_unit_index,
                       int core_unit_index);

  ToitdocRegistry toitdocs() { return toitdocs_; }

 private:
  SourceManager* source_manager_;
  Diagnostics* diagnostics_;
  UnorderedMap<ir::Node*, ast::Node*> ir_to_ast_map_;
  ToitdocRegistry toitdocs_;

  Lsp* lsp_;

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
};

} // namespace toit::compiler
} // namespace toit

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

#pragma once

#include "../top.h"

#include "lsp.h"
#include "sources.h"

namespace toit {
namespace compiler {

/// A target handler is invoked when the target of a LSP command is encountered.
class GotoDefinitionHandler : public LspSelectionHandler {
 public:
  explicit GotoDefinitionHandler(SourceManager* source_manager)
      : _source_manager(source_manager) { }

  void class_or_interface(ast::Node* node, IterableScope* scope, ir::Class* holder, ir::Node* resolved, bool needs_interface);
  void type(ast::Node* node, IterableScope* scope, ResolutionEntry resolved, bool allow_none);
  void call_virtual(ir::CallVirtual* node, ir::Type type, List<ir::Class*> classes);
  void call_prefixed(ast::Dot* node,
                     ir::Node* resolved1,
                     ir::Node* resolved2,
                     List<ir::Node*> candidates,
                     IterableScope* scope);
  void call_class(ast::Dot* node,
                  ir::Class* klass,
                  ir::Node* resolved1,
                  ir::Node* resolved2,
                  List<ir::Node*> candidates,
                  IterableScope* scope);
  void call_static(ast::Node* node,
                   ir::Node* resolved1,
                   ir::Node* resolved2,
                   List<ir::Node*> candidates,
                   IterableScope* scope,
                   ir::Method* surrounding);
  void call_block(ast::Dot* node, ir::Node* ir_receiver);
  void call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates);

  void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                      int module, int primitive, bool on_module);

  void field_storing_parameter(ast::Parameter* node,
                               List<ir::Field*> fields,
                               bool field_storing_is_allowed);

  void this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding);

  void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope);

  void return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels);

  void toitdoc_ref(ast::Node* node,
                   List<ir::Node*> candidates,
                   ToitdocScopeIterator* iterator,
                   bool is_signature_toitdoc);

  static void import_path(const char* resolved);

 private:
  SourceManager* _source_manager;
  UnorderedSet<Source::Range> _printed_definitions;

  void call_statically_resolved(ir::Node* resolved1, ir::Node* resolved2, List<ir::Node*> candidates);
  void _print_range(ir::Node* resolved);
  void _print_range(Source::Range range);
  void _print_all(ResolutionEntry entry);
  void _print_all(List<ir::Node*> nodes);
};

} // namespace toit::compiler
} // namespace toit

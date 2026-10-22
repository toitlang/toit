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

#include "../ast_resolution.h"
#include "../../top.h"

#include "selection.h"
#include "../sources.h"

namespace toit {
namespace compiler {

/// A target handler is invoked when the target of a LSP command is encountered.
class GotoDefinitionHandler : public LspSelectionHandler {
 public:
  explicit GotoDefinitionHandler(SourceManager* source_manager, LspProtocol* protocol)
      : LspSelectionHandler(protocol)
      , source_manager_(source_manager) {}

  /// Finishes the goto-definition request.
  ///
  /// This invokes exit(0).
  void terminate();

  void import_path(const char* path,
                   const char* segment,
                   bool is_first_segment,
                   const char* resolved,
                   const Package& current_package,
                   const PackageLock& package_lock,
                   Filesystem* fs);
  void class_interface_or_mixin(ast::Node* node,
                                IterableScope* scope,
                                resolution::View<resolution::Class> holder,
                                resolution::View<resolution::Node> resolved,
                                bool needs_interface,
                                bool needs_mixin);
  void type(ast::Node* node, IterableScope* scope, ResolutionEntry resolved, bool allow_none);
  void call_virtual(resolution::View<resolution::CallVirtual> node, resolution::Type type, List<resolution::View<resolution::Class>> classes);
  void call_prefixed(ast::Dot* node,
                     resolution::View<resolution::Node> resolved1,
                     resolution::View<resolution::Node> resolved2,
                     List<resolution::View<resolution::Node>> candidates,
                     IterableScope* scope);
  void call_class(ast::Dot* node,
                  resolution::View<resolution::Class> klass,
                  resolution::View<resolution::Node> resolved1,
                  resolution::View<resolution::Node> resolved2,
                  List<resolution::View<resolution::Node>> candidates,
                  IterableScope* scope);
  void call_static(ast::Node* node,
                   resolution::View<resolution::Node> resolved1,
                   resolution::View<resolution::Node> resolved2,
                   List<resolution::View<resolution::Node>> candidates,
                   IterableScope* scope,
                   resolution::View<resolution::Method> surrounding);
  void call_block(ast::Dot* node, resolution::View<resolution::Node> ir_receiver);
  void call_static_named(ast::Node* name_node, resolution::View<resolution::Node> ir_call_target, List<resolution::View<resolution::Node>> candidates);

  void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                      int module, int primitive, bool on_module);

  void field_storing_parameter(ast::Parameter* node,
                               List<resolution::View<resolution::Field>> fields,
                               bool field_storing_is_allowed);

  void this_(ast::Identifier* node, resolution::View<resolution::Class> enclosing_class, IterableScope* scope, resolution::View<resolution::Method> surrounding);

  void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope);

  void expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope);

  void return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels);

  void toitdoc_ref(ast::Node* node,
                   List<resolution::View<resolution::Node>> candidates,
                   ToitdocScopeIterator* iterator,
                   bool is_signature_toitdoc);

  void definition(resolution::View<resolution::Node> ir_node, Source::Range name_range) override {}

  static void import_path(const char* resolved, LspProtocol* protocol);

 private:
  SourceManager* source_manager_;
  UnorderedSet<Source::Range> printed_definitions_;

  void call_statically_resolved(resolution::View<resolution::Node> resolved1, resolution::View<resolution::Node> resolved2, List<resolution::View<resolution::Node>> candidates);
  void _print_range(resolution::View<resolution::Node> resolved);
  void _print_range(Source::Range range);
  void _print_all(ResolutionEntry entry);
  void _print_all(List<resolution::View<resolution::Node>> nodes);
};

} // namespace toit::compiler
} // namespace toit

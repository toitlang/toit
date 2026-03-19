// Copyright (C) 2026 Toit contributors.
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

#include "selection.h"
#include "../toitdoc.h"

namespace toit {
namespace compiler {

class HoverHandler : public LspSelectionHandler {
 public:
  HoverHandler(SourceManager* source_manager,
               ToitdocRegistry* toitdocs,
               LspProtocol* protocol)
      : LspSelectionHandler(protocol)
      , source_manager_(source_manager)
      , toitdocs_(toitdocs) {}

  void import_path(const char* path,
                   const char* segment,
                   bool is_first_segment,
                   const char* resolved,
                   const Package& current_package,
                   const PackageLock& package_lock,
                   Filesystem* fs) override;

  void class_interface_or_mixin(ast::Node* node,
                                IterableScope* scope,
                                ir::Class* holder,
                                ir::Node* resolved,
                                bool needs_interface,
                                bool needs_mixin) override;

  void type(ast::Node* node,
            IterableScope* scope,
            ResolutionEntry resolved,
            bool allow_none) override;

  void call_virtual(ir::CallVirtual* node,
                    ir::Type type,
                    List<ir::Class*> classes) override;

  void call_prefixed(ast::Dot* node,
                     ir::Node* resolved1,
                     ir::Node* resolved2,
                     List<ir::Node*> candidates,
                     IterableScope* scope) override;

  void call_class(ast::Dot* node,
                  ir::Class* klass,
                  ir::Node* resolved1,
                  ir::Node* resolved2,
                  List<ir::Node*> candidates,
                  IterableScope* scope) override;

  void call_static(ast::Node* node,
                   ir::Node* resolved1,
                   ir::Node* resolved2,
                   List<ir::Node*> candidates,
                   IterableScope* scope,
                   ir::Method* surrounding) override;

  void call_block(ast::Dot* node, ir::Node* ir_receiver) override;

  void call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) override;

  void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                      int module, int primitive, bool on_module) override;

  void field_storing_parameter(ast::Parameter* node,
                               List<ir::Field*> fields,
                               bool field_storing_is_allowed) override;

  void this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding) override;

  void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) override;

  void expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) override;

  void return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) override;

  void toitdoc_ref(ast::Node* node,
                   List<ir::Node*> candidates,
                   ToitdocScopeIterator* iterator,
                   bool is_signature_toitdoc) override;

  /// Retries deferred hover lookups after all modules are resolved.
  ///
  /// When `emit_hover` is called during resolution of the entry module,
  /// imported modules may not have their toitdocs populated yet. In that
  /// case, the node is cached and `finalize` retries the lookup.
  void finalize();

 private:
  SourceManager* source_manager_;
  ToitdocRegistry* toitdocs_;
  ir::Node* deferred_node_ = null;
  bool has_emitted_ = false;

  void emit_hover(ir::Node* node, const char* name);
};

} // namespace toit::compiler
} // namespace toit

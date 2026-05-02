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

#include "../set.h"
#include "../token.h"
#include "../resolver.h"

namespace toit {
namespace compiler {

// TODO: It might be interesting to split the LSP handler in two: one that is
// called early (during resolution), and then a later post-resolution (or even
// post-type) phase that does the actual work with the stored information.
// We already do something similar with the 'hover' where we have a later
// 'finalize' call.
class FindReferencesHandler : public LspSelectionHandler {
 public:
  FindReferencesHandler(SourceManager* source_manager, LspProtocol* protocol)
      : LspSelectionHandler(protocol), source_manager_(source_manager) {}

  void import_path(const char* path,
                   const char* segment,
                   bool is_first_segment,
                   const char* resolved,
                   const Package& current_package,
                   const PackageLock& package_lock,
                   Filesystem* fs) override {}

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

  void call_virtual(ir::CallVirtual* node, ir::Type type, List<ir::Class*> classes) override;

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

  void call_block(ast::Dot* node, ir::Node* ir_receiver) override {}

  void call_static_named(ast::Node* name_node,
                         ir::Node* ir_call_target,
                         List<ir::Node*> candidates) override;

  void call_primitive(ast::Node* node,
                      Symbol module_name,
                      Symbol primitive_name,
                      int module,
                      int primitive,
                      bool on_module) override {}

  void field_storing_parameter(ast::Parameter* node,
                               List<ir::Field*> fields,
                               bool field_storing_is_allowed) override;

  void this_(ast::Identifier* node,
             ir::Class* enclosing_class,
             IterableScope* scope,
             ir::Method* surrounding) override {}

  void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) override;
  void expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) override;

  void return_label(ast::Node* node,
                    int label_index,
                    const std::vector<std::pair<Symbol, ast::Node*>>& labels) override {}

  void toitdoc_ref(ast::Node* node,
                   List<ir::Node*> candidates,
                   ToitdocScopeIterator* iterator,
                   bool is_signature_toitdoc) override;

  void definition(ir::Node* ir_node, Source::Range name_range) override;

  ir::Node* target() const { return target_; }
  /// Returns the source range at the cursor position (the usage site).
  ///
  /// This is the range of the identifier the user clicked on, which may
  /// differ from target_range(target()) when the cursor is on a reference
  /// rather than the definition. Used by prepareRename to return the
  /// correct range to the editor.
  Source::Range cursor_range() const { return cursor_range_; }
  SourceManager* source_manager() const { return source_manager_; }

 private:
  void handle_show_or_export(ast::Node* node, ResolutionEntry entry);

  SourceManager* source_manager_;
  ir::Node* target_ = null;
  Source::Range cursor_range_ = Source::Range::invalid();
};

/// Finds all references to [target] in the program and emits them via
/// the protocol's find_references channel.
///
/// This function handles all reference types: static references, virtual
/// call sites, class hierarchy references (extends/implements/with),
/// type annotations, field-storing parameters, show/export clauses,
/// and toitdoc references.
///
/// Does not return — calls exit(0) after emitting all references.
void find_and_emit_all_references(
    ir::Node* target,
    ir::Program* program,
    SourceManager* source_manager,
    UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast,
    LspProtocol* protocol,
    ToitdocRegistry* toitdocs,
    const std::vector<Resolver::ShowExportReference>& show_export_references,
    const std::vector<Resolver::ClassHierarchyReference>& class_hierarchy_references);

} // namespace toit::compiler
} // namespace toit

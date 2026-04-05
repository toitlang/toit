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

#include "../../top.h"

#include "protocol.h"
#include "completion.h"
#include "goto_definition.h"
#include "selection_range.h"
#include "semantic.h"
#include "hover.h"
#include "rename.h"

namespace toit {
namespace compiler {

/// The facade for Language-Server interaction.
///
/// The compiler is not talking directly to an LSP client, but communicates with
/// an LSP server. Whenever the LSP server needs information (like diagnostics...)
/// it spawns the compiler with the correct argumens and receives the information
/// it needs.
class Lsp {
 public:
  explicit Lsp(LspProtocol* protocol) : protocol_(protocol) {}
  ~Lsp() {
    if (selection_handler_ != null) {
      delete selection_handler_;
      selection_handler_ = null;
    }
  }

  void setup_completion_handler(SourceManager* source_manager) {
    ASSERT(selection_handler_ == null);
    selection_handler_ = _new CompletionHandler(source_manager, protocol());
  }

  void setup_goto_definition_handler(SourceManager* source_manager) {
    ASSERT(selection_handler_ == null);
    selection_handler_ = _new GotoDefinitionHandler(source_manager, protocol());
  }

  void setup_hover_handler(SourceManager* source_manager,
                           ToitdocRegistry* toitdocs) {
    ASSERT(selection_handler_ == null);
    selection_handler_ = _new HoverHandler(source_manager, toitdocs, protocol());
  }

  void setup_find_references_handler(SourceManager* source_manager) {
    ASSERT(selection_handler_ == null);
    selection_handler_ = _new FindReferencesHandler(source_manager, protocol());
  }

  bool has_selection_handler() const { return selection_handler_ != null; }
  LspSelectionHandler* selection_handler() { return selection_handler_; }

  LspProtocol* protocol() { return protocol_; }

  LspDiagnosticsProtocol* diagnostics() { return protocol()->diagnostics(); }
  LspSnapshotProtocol* snapshot() { return protocol()->snapshot(); }

  bool needs_summary() const { return needs_summary_; }
  void set_needs_summary(bool value) { needs_summary_ = value; }
  void emit_summary(const std::vector<Module*>& modules,
                    int core_index,
                    const ToitdocRegistry& toitdocs) {
    protocol()->summary()->emit(modules, core_index, toitdocs);
  }

  bool should_emit_semantic_tokens() const { return should_emit_semantic_tokens_; }
  void set_should_emit_semantic_tokens(bool value) { should_emit_semantic_tokens_ = value; }
  void emit_semantic_tokens(Module* module, const char* path, SourceManager* manager) {
    emit_tokens(module, path, manager, protocol());
  }

  void set_selection_range_request(const char* path,
                                   const std::vector<std::pair<int, int>>& positions) {
    selection_range_path_ = path;
    selection_range_positions_ = positions;
  }

  /// Called after parsing, before resolution.
  ///
  /// Handlers that only need the parsed AST (e.g. selection ranges) can act
  /// here and call exit(0). Other modes ignore this call.
  void parsed_units(const std::vector<ast::Unit*>& units,
                    SourceManager* source_manager) {
    if (selection_range_path_ == null) return;
    for (auto* unit : units) {
      if (unit->is_error_unit()) continue;
      if (strcmp(unit->absolute_path(), selection_range_path_) == 0) {
        compiler::emit_selection_ranges(unit,
                                        selection_range_positions_,
                                        source_manager,
                                        protocol());
        exit(0);
      }
    }
    // File not found among parsed units — emit empty results.
    for (size_t i = 0; i < selection_range_positions_.size(); i++) {
      protocol()->selection_range()->emit_range_count(0);
    }
    exit(0);
  }

 private:
  LspProtocol* protocol_;
  LspSelectionHandler* selection_handler_ = null;
  bool needs_summary_ = false;
  bool should_emit_semantic_tokens_ = false;
  const char* selection_range_path_ = null;
  std::vector<std::pair<int, int>> selection_range_positions_;
};

} // namespace toit::compiler
} // namespace toit

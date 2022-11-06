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
#include "semantic.h"

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

  void setup_completion_handler(Symbol prefix, const std::string package_id, SourceManager* source_manager) {
    ASSERT(selection_handler_ == null);
    selection_handler_ = _new CompletionHandler(prefix, package_id, source_manager, protocol());
  }

  void setup_goto_definition_handler(SourceManager* source_manager) {
    ASSERT(selection_handler_ == null);
    selection_handler_ = _new GotoDefinitionHandler(source_manager, protocol());
  }

  bool has_selection_handler() const { return selection_handler_ != null; }
  LspSelectionHandler* selection_handler() { return selection_handler_; }

  // Completion of the first segment happens before the selection handler is set up.
  void complete_first_segment(Symbol prefix,
                              ast::Identifier* segment,
                              const Package& current_package,
                              const PackageLock& package_lock) {
      CompletionHandler::import_first_segment(prefix,
                                              segment,
                                              current_package,
                                              package_lock,
                                              protocol());
  }

  // Completion of the import path happens before the selection handler is set up.
  void complete_import_path(Symbol prefix, const char* path, Filesystem* fs) {
    CompletionHandler::import_path(prefix, path, fs, protocol());
  }

  // Goto-definitin of the import path happens before the selection handler is set up.
  void goto_definition_import_path(const char* resolved) {
    GotoDefinitionHandler::import_path(resolved, protocol());
  }

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

 private:
  LspProtocol* protocol_;
  LspSelectionHandler* selection_handler_ = null;
  bool needs_summary_ = false;
  bool should_emit_semantic_tokens_ = false;
};

} // namespace toit::compiler
} // namespace toit

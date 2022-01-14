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
  explicit Lsp(LspProtocol* protocol) : _protocol(protocol) { }
  ~Lsp() {
    if (_selection_handler != null) {
      delete _selection_handler;
      _selection_handler = null;
    }
  }

  void setup_completion_handler(Symbol prefix, const std::string package_id, SourceManager* source_manager) {
    ASSERT(_selection_handler == null);
    _selection_handler = _new CompletionHandler(prefix, package_id, source_manager, protocol());
  }

  void setup_goto_definition_handler(SourceManager* source_manager) {
    ASSERT(_selection_handler == null);
    _selection_handler = _new GotoDefinitionHandler(source_manager, protocol());
  }

  bool has_selection_handler() const { return _selection_handler != null; }
  LspSelectionHandler* selection_handler() { return _selection_handler; }

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

  LspProtocol* protocol() { return _protocol; }

  LspDiagnosticsProtocol* diagnostics() { return protocol()->diagnostics(); }
  LspSnapshotProtocol* snapshot() { return protocol()->snapshot(); }

  bool needs_summary() const { return _needs_summary; }
  void set_needs_summary(bool value) { _needs_summary = value; }
  void emit_summary(const std::vector<Module*>& modules,
                    int core_index,
                    const ToitdocRegistry& toitdocs) {
    protocol()->summary()->emit(modules, core_index, toitdocs);
  }

  bool should_emit_semantic_tokens() const { return _should_emit_semantic_tokens; }
  void set_should_emit_semantic_tokens(bool value) { _should_emit_semantic_tokens = value; }
  void emit_semantic_tokens(Module* module, const char* path, SourceManager* manager) {
    emit_tokens(module, path, manager, protocol());
  }

 private:
  LspProtocol* _protocol;
  LspSelectionHandler* _selection_handler = null;
  bool _needs_summary = false;
  bool _should_emit_semantic_tokens = false;
};

} // namespace toit::compiler
} // namespace toit

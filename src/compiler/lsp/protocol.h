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

#include <vector>
#include <string>
#include <stdarg.h>

#include "../../top.h"

#include "../diagnostic.h"
#include "../list.h"
#include "../map.h"
#include "../sources.h"
#include "completion_kind.h"

namespace toit {
class SnapshotBundle;

namespace compiler {

class Module;
class ToitdocRegistry;

/// This range class uses the LSP conventions.
/// Contrary to the compiler range all integers are 0-indexed.
struct LspRange {
  const char* path;
  // All entries are 0-indexed.
  int from_line;
  int from_column;
  int to_line;
  int to_column;
};

int utf16_offset_in_line(Source::Location location);
LspRange range_to_lsp_range(Source::Range range, SourceManager* manager);

struct LspWriter {
  virtual ~LspWriter() {}
  virtual void printf(const char* format, va_list& arguments) = 0;
  virtual void write(const uint8* data, int size) = 0;
};

struct LspWriterStdout : public LspWriter {
  void printf(const char* format, va_list& arguments) {
    vprintf(format, arguments);
  }

  void write(const uint8* data, int size) {
    int written = fwrite(data, 1, size, stdout);
    fflush(stdout);
    if (written != size) FATAL("Couldn't write data");
  }
};

class LspProtocolBase {
 public:
  LspProtocolBase(LspWriter* writer) : _writer(writer) { }

 protected:
  void print_lsp_range(const LspRange& range);

  void printf(const char* format, va_list& arguments) {
    _writer->printf(format, arguments);
  }

  void printf(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    printf(format, arguments);
    va_end(arguments);
  }

  void write(const uint8* data, int size) {
    _writer->write(data, size);
  }

  LspWriter* writer() { return _writer; }

 private:
  LspWriter* _writer;
};

class LspDiagnosticsProtocol : public LspProtocolBase {
 public:
  // Inherit constructor.
  using LspProtocolBase::LspProtocolBase;

  void emit(Diagnostics::Severity severity, const char* format, va_list& arguments);
  void emit(Diagnostics::Severity severity,
            const LspRange& range,
            const char* format,
            va_list& arguments);
  void start_group();
  void end_group();
};

class LspGotoDefinitionProtocol : public LspProtocolBase {
 public:
  // Inherit constructor.
  using LspProtocolBase::LspProtocolBase;

  void emit(const LspRange& range);
};

class LspCompletionProtocol : public LspProtocolBase {
 public:
  // Inherit constructor.
  using LspProtocolBase::LspProtocolBase;

  void emit(const std::string& name,
            CompletionKind kind);
};

class LspSummaryProtocol : public LspProtocolBase {
 public:
  // Inherit constructor.
  using LspProtocolBase::LspProtocolBase;

  void emit(const std::vector<Module*>& modules,
            int core_index,
            const ToitdocRegistry& toitdocs);
};

class LspSnapshotProtocol : public LspProtocolBase {
 public:
  // Inherit constructor.
  using LspProtocolBase::LspProtocolBase;

  void fail();
  void emit(const SnapshotBundle& bundle);
};

class LspSemanticTokensProtocol : public LspProtocolBase {
 public:
  // Inherit constructor.
  using LspProtocolBase::LspProtocolBase;

  // The number of tokens.
  void emit_size(int size);

  void emit_token(int delta_line,
                  int delta_column,
                  int token_length,
                  int encoded_token_type,
                  int token_modifiers);
};

/// The protocol with which the compiler talks to the LSP server.
///
/// *Note*: this protocol is not the same as the one between an LSP client and
/// the LSP server.
///
/// The protocol has been split into sub-protocols. This is for convenience and
/// readability. All protocol functions could also just be merged into the same
/// class.
class LspProtocol {
 public:
  explicit LspProtocol(LspWriter* writer)
      : _diagnostics(writer)
      , _goto_definition(writer)
      , _completion(writer)
      , _summary(writer)
      , _snapshot(writer)
      , _semantic(writer) {
  }

  LspDiagnosticsProtocol* diagnostics() { return &_diagnostics; }
  LspGotoDefinitionProtocol* goto_definition() { return &_goto_definition; }
  LspCompletionProtocol* completion() { return &_completion; }
  LspSummaryProtocol* summary() { return &_summary; }
  LspSnapshotProtocol* snapshot() { return &_snapshot; }
  LspSemanticTokensProtocol* semantic() { return &_semantic; }

 private:
  LspDiagnosticsProtocol _diagnostics;
  LspGotoDefinitionProtocol _goto_definition;
  LspCompletionProtocol _completion;
  LspSummaryProtocol _summary;
  LspSnapshotProtocol _snapshot;
  LspSemanticTokensProtocol _semantic;
};

} // namespace toit::compiler
} // namespace toit

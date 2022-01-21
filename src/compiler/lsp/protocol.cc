// Copyright (C) 2022 Toitware ApS.
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

#include "protocol.h"

#include <stdio.h>
#include <functional>

#include "protocol_summary.h"

#include "../toitdoc_node.h"
#include "../set.h"
#include "../list.h"
#include "../map.h"
#include "../resolver_scope.h"

#include "../../snapshot_bundle.h"
#include "../../utils.h"

namespace toit {
namespace compiler {

int utf16_offset_in_line(Source::Location location) {
  int utf8_offset_in_line = location.offset_in_line;
  const uint8* text = location.source->text();
  int line_start_offset = location.line_offset;

  int result = 0;
  int source_index = line_start_offset;
  while (source_index < line_start_offset + utf8_offset_in_line) {
    int nb_bytes = Utils::bytes_in_utf_8_sequence(text[source_index]);
    source_index += nb_bytes;
    if (nb_bytes <= 3) {
      result++;
    } else {
      // Surrogate pair or 4-byte UTF-8 encoding needed above 0xFFFF.
      result += 2;
    }
  }
  return result;
}

LspRange range_to_lsp_range(Source::Range range, SourceManager* source_manager) {
  auto from_location = source_manager->compute_location(range.from());
  auto to_location = source_manager->compute_location(range.to());

  ASSERT(from_location.source->absolute_path() != null);
  ASSERT(strcmp(from_location.source->absolute_path(), to_location.source->absolute_path()) == 0);

  return LspRange {
    .path = from_location.source->absolute_path(),
    .from_line = from_location.line_number - 1,
    .from_column = utf16_offset_in_line(from_location),
    .to_line = to_location.line_number - 1,
    .to_column = utf16_offset_in_line(to_location),
  };
}

void LspProtocolBase::print_lsp_range(const LspRange& range) {
  this->printf("%s\n", range.path);
  this->printf("%d\n%d\n", range.from_line, range.from_column);
  this->printf("%d\n%d\n", range.to_line, range.to_column);
}

static const char* severity_to_lsp_severity(Diagnostics::Severity severity) {
  switch (severity) {
    case Diagnostics::Severity::warning: return "warning";
    case Diagnostics::Severity::error: return "error";
    case Diagnostics::Severity::note: return "information";
  }
  UNREACHABLE();
}

void LspDiagnosticsProtocol::emit(Diagnostics::Severity severity, const char* format, va_list& arguments) {
  this->printf("NO POSITION\n");
  this->printf("%s\n", severity_to_lsp_severity(severity));
  this->printf(format, arguments);
  this->printf("\n*******************\n");
}

void LspDiagnosticsProtocol::emit(Diagnostics::Severity severity,
                                  const LspRange& range,
                                  const char* format,
                                  va_list& arguments) {
  this->printf("WITH POSITION\n");
  this->printf("%s\n", severity_to_lsp_severity(severity));
  print_lsp_range(range);
  this->printf(format, arguments);
  this->printf("\n*******************\n");
}

void LspDiagnosticsProtocol::start_group() {
  this->printf("START GROUP\n");
}

void LspDiagnosticsProtocol::end_group() {
  this->printf("END GROUP\n");
}

void LspGotoDefinitionProtocol::emit(const LspRange& range) {
  print_lsp_range(range);
}

void LspCompletionProtocol::emit(const std::string& name,
                                 CompletionKind kind) {
  this->printf("%s\n%d\n", name.c_str(), static_cast<int>(kind));
}

void LspSnapshotProtocol::fail() {
  this->printf("FAIL\n");
}

void LspSnapshotProtocol::emit(const SnapshotBundle& bundle) {
  // The SnapshotBundle constructor copies all data.
  this->printf("OK\n%d\n", bundle.size());
  this->write(bundle.buffer(), bundle.size());
}

void LspSummaryProtocol::emit(const std::vector<Module*>& modules,
                              int core_index,
                              const ToitdocRegistry& toitdocs) {
  emit_summary(modules, core_index, toitdocs, writer());
}

void LspSemanticTokensProtocol::emit_size(int size) {
  this->printf("%d\n", (size * 5));
}

void LspSemanticTokensProtocol::emit_token(int delta_line,
                                           int delta_column,
                                           int token_length,
                                           int encoded_token_type,
                                           int token_modifiers) {
  this->printf("%d\n%d\n%d\n%d\n%d\n",
               delta_line,
               delta_column,
               token_length,
               encoded_token_type,
               token_modifiers);
}



} // namespace toit::compiler
} // namespace toit

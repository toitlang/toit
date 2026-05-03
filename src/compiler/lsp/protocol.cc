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

#include "protocol_summary.h"

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

static LspRange range_to_lsp_range(const Source::Location& from_location,
                                   const Source::Location& to_location) {
  return LspRange {
    .from_line = from_location.line_number - 1,
    .from_column = utf16_offset_in_line(from_location),
    .to_line = to_location.line_number - 1,
    .to_column = utf16_offset_in_line(to_location),
  };
}

LspLocation range_to_lsp_location(Source::Range range, SourceManager* source_manager) {
  auto from_location = source_manager->compute_location(range.from());
  auto to_location = source_manager->compute_location(range.to());

  ASSERT(from_location.source->absolute_path() != null);
  ASSERT(strcmp(from_location.source->absolute_path(), to_location.source->absolute_path()) == 0);

  return LspLocation {
    .path = from_location.source->absolute_path(),
    .range = range_to_lsp_range(from_location, to_location),
  };
}

LspRange range_to_lsp_range(Source::Range range, SourceManager* source_manager) {
  auto from_location = source_manager->compute_location(range.from());
  auto to_location = source_manager->compute_location(range.to());

  ASSERT(from_location.source->absolute_path() != null);
  ASSERT(strcmp(from_location.source->absolute_path(), to_location.source->absolute_path()) == 0);

  return range_to_lsp_range(from_location, to_location);
}

void LspProtocolBase::write_location(const LspLocation& location) {
  this->printf("%s\n", location.path);
  write_range(location.range);
}

void LspProtocolBase::write_range(const LspRange& range) {
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
                                  const LspLocation& location,
                                  const char* format,
                                  va_list& arguments) {
  this->printf("WITH POSITION\n");
  this->printf("%s\n", severity_to_lsp_severity(severity));
  write_location(location);
  this->printf(format, arguments);
  this->printf("\n*******************\n");
}

void LspDiagnosticsProtocol::start_group() {
  this->printf("START GROUP\n");
}

void LspDiagnosticsProtocol::end_group() {
  this->printf("END GROUP\n");
}

void LspGotoDefinitionProtocol::emit(const LspLocation& location) {
  write_location(location);
}

void LspCompletionProtocol::emit_prefix(const char* prefix) {
  this->printf("%s\n", prefix);
}

void LspCompletionProtocol::emit_prefix_range(const LspRange& range) {
  write_range(range);
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

void LspHoverProtocol::emit_toitdoc_ref(const char* path, int start, int end) {
  this->printf("-1\n%s\n%d\n%d\n",
               path == null ? "" : path,
               start,
               end);
}

void LspHoverProtocol::emit_string(const char* content) {
  int length = content == null ? 0 : strlen(content);
  this->printf("%d\n", length);
  if (length > 0) {
    this->write(reinterpret_cast<const uint8*>(content), length);
  }
}

void LspFindReferencesProtocol::emit(const char* path, int start_line, int start_col, int end_line, int end_col) {
  this->printf("%s\n%d\n%d\n%d\n%d\n",
               path == null ? "" : path,
               start_line,
               start_col,
               end_line,
               end_col);
}

void LspPrepareRenameProtocol::emit(const char* path, int start_line, int start_col,
                                    int end_line, int end_col, const char* placeholder) {
  this->printf("%s\n%d\n%d\n%d\n%d\n%s\n",
               path == null ? "" : path,
               start_line,
               start_col,
               end_line,
               end_col,
               placeholder == null ? "" : placeholder);
}

void LspSelectionRangeProtocol::emit_range_count(int count) {
  this->printf("%d\n", count);
}

void LspSelectionRangeProtocol::emit_range(const LspRange& range) {
  write_range(range);
}

} // namespace toit::compiler
} // namespace toit

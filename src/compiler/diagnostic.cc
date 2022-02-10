// Copyright (C) 2018 Toitware ApS.
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

#include <stdio.h>
#include <string.h>
#include <stdarg.h>

#include "ast.h"
#include "diagnostic.h"
#include "lsp/lsp.h"
#include "package.h"
#include "scanner.h"

#include "../utils.h"
#ifdef TOIT_POSIX
#include "third_party/termcolor-c/termcolor-c.h"
#else
static FILE* reset_colors(FILE* f) { return f; }
static FILE* text_bold(FILE* f) { return f; }
static FILE* text_magenta(FILE* f) { return f; }
static FILE* text_red(FILE* f) { return f; }
static FILE* text_green(FILE* f) { return f; }
#endif

namespace toit {
namespace compiler {

void Diagnostics::report_error(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_error(format, arguments);
  va_end(arguments);
}

void Diagnostics::report_error(const char* format, va_list& arguments) {
  report(Severity::error, format, arguments);
}

void Diagnostics::report_error(Source::Range range, const char* format, va_list& arguments) {
  report(Severity::error, range, format, arguments);
}

void Diagnostics::report_error(Source::Range range, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_error(range, format, arguments);
  va_end(arguments);
}

void Diagnostics::report_error(const ast::Node* position_node, const char* format, ...) {
  auto range = position_node->range();
  va_list arguments;
  va_start(arguments, format);
  report_error(range, format, arguments);
  va_end(arguments);
}

void Diagnostics::report_warning(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_warning(format, arguments);
  va_end(arguments);
}

void Diagnostics::report_warning(const char* format, va_list& arguments) {
  report(Severity::warning, format, arguments);
}

void Diagnostics::report_warning(Source::Range range, const char* format, va_list& arguments) {
  report(Severity::warning, range, format, arguments);
}

void Diagnostics::report_warning(Source::Range range, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_warning(range, format, arguments);
  va_end(arguments);
}

void Diagnostics::report_warning(const ast::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_warning(position_node->range(), format, arguments);
  va_end(arguments);
}

void Diagnostics::report_note(const ast::Node* position_node, const char* format, ...) {
  auto range = position_node->range();
  va_list arguments;
  va_start(arguments, format);
  report_note(range, format, arguments);
  va_end(arguments);
}

void Diagnostics::report_note(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_note(format, arguments);
  va_end(arguments);
}

void Diagnostics::report_note(const char* format, va_list& arguments) {
  report(Severity::note, format, arguments);
}

void Diagnostics::report_note(Source::Range range, const char* format, va_list& arguments) {
  report(Severity::note, range, format, arguments);
}

void Diagnostics::report_note(Source::Range range, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  report_note(range, format, arguments);
  va_end(arguments);
}

void Diagnostics::report_location(Source::Range range, const char* prefix) {
  auto from_location = source_manager()->compute_location(range.from());

  const char* path = from_location.source->absolute_path();
  int offset_in_source = from_location.offset_in_source;
  int line_number = from_location.line_number;
  int offset_in_line = from_location.offset_in_line;
  int column_number = offset_in_line + 1;  // 1-based.

  fprintf(stderr, "%s %s:%d:%d %d\n", prefix, path, line_number, column_number, offset_in_source);
}

void CompilationDiagnostics::emit(Severity severity, const char* format, va_list& arguments) {
  vprintf(format, arguments);
  putchar('\n');
}

void CompilationDiagnostics::start_group() {
  ASSERT(!_in_group);
  _in_group = true;
  _group_package_id = Package::INVALID_PACKAGE_ID;
}

void CompilationDiagnostics::end_group() {
  _in_group = false;
}

void CompilationDiagnostics::emit(Severity severity,
                                  Source::Range range,
                                  const char* format,
                                  va_list& arguments) {
  auto from_location = source_manager()->compute_location(range.from());

  if (!_show_package_warnings) {
    Severity error_severity;
    std::string error_package_id;
    if (_in_group) {
      // For groups, the first encountered error defines where the error comes
      // from. Subsequent diagnostics in the group use that package id.
      if (_group_package_id == Package::INVALID_PACKAGE_ID) {
        _group_package_id = from_location.source->package_id();
        _group_severity = severity;
      }
      error_package_id = _group_package_id;
      error_severity = _group_severity;
    } else {
      error_package_id = from_location.source->package_id();
      error_severity = severity;
    }

    if (error_package_id != Package::ENTRY_PACKAGE_ID) {
      switch (error_severity) {
        case Severity::error:
          break;
        case Severity::warning:
        case Severity::note:
          return;
      }
    }
  }

  const char* absolute_path = from_location.source->absolute_path();
  std::string error_path = from_location.source->error_path();
  const uint8* source = from_location.source->text();
  int offset_in_source = from_location.offset_in_source;
  int line_offset = from_location.line_offset;
  int line_number = from_location.line_number;
  int offset_in_line = from_location.offset_in_line;
  int column_number = offset_in_line + 1;  // 1-based.

  FILE* (*color_fun)(FILE*) = null;

  text_bold(stdout);
  if (absolute_path != null) {
    printf("%s:%d:%d: ", error_path.c_str(), line_number, column_number);
  }
  switch (severity) {
    case Severity::warning:
      color_fun = &text_magenta;
      (*color_fun)(stdout);
      printf("warning: ");
      break;
    case Severity::error:
      color_fun = &text_red;
      (*color_fun)(stdout);
      printf("error: ");
      break;
    case Severity::note:
      color_fun = &text_green;
      (*color_fun)(stdout);
      printf("note: ");
      break;
  }
  reset_colors(stdout);
  vprintf(format, arguments);
  putchar('\n');

  // Print the source line.

  int index = line_offset;
  while (true) {
    int c = source[index++];
    if (c == 0 || is_newline(c)) break;
    putchar(c);
  }
  putchar('\n');

  // Skip over Windows newline.
  if (source[index - 1] == '\r' && source[index] == '\n') index++;

  // Print the `^~~~` at the correct location.

  (*color_fun)(stdout);
  index = line_offset;
  while (index < offset_in_source) {
    int c = source[index];
    // Keep tabs, to make it more likely that the ^ aligns correctly.
    putchar(c == '\t' ? '\t' : ' ');
    // UTF-8 multi-byte sequences are just treated like one character.
    index += Utils::bytes_in_utf_8_sequence(c);
  }
  printf("^");
  index += Utils::bytes_in_utf_8_sequence(source[index]);

  auto to_location = source_manager()->compute_location(range.to());
  ASSERT(strcmp(to_location.source->absolute_path(), absolute_path) == 0);
  if (to_location.line_number == line_number) {
    while (index < to_location.offset_in_source) {
      // We are treating tabs as if they had a width of 1.
      // This means that the `~` lines will sometimes be too short, but we don't
      // have a good way to do better.

      // UTF-8 multi-byte sequences are just treated like one character.
      index += Utils::bytes_in_utf_8_sequence(source[index]);
      printf("~");
    }
  }
  printf("\n");
  reset_colors(stdout);
}

void LanguageServerAnalysisDiagnostics::emit(Severity severity, const char* format, va_list& arguments) {
  lsp()->diagnostics()->emit(severity, format, arguments);
}

void LanguageServerAnalysisDiagnostics::emit(Severity severity,
                                             Source::Range range,
                                             const char* format,
                                             va_list& arguments) {
  lsp()->diagnostics()->emit(severity,
                             range_to_lsp_range(range, source_manager()),
                             format,
                             arguments);
}

void LanguageServerAnalysisDiagnostics::start_group() {
  lsp()->diagnostics()->start_group();
}

void LanguageServerAnalysisDiagnostics::end_group() {
  lsp()->diagnostics()->end_group();
}

} // namespace toit::compiler
} // namespace toit

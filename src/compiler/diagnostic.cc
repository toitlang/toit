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

const char* const NO_WARN_MARKER = "// @no-warn";

void Diagnostics::report(Severity severity, const char* format, va_list& arguments) {
  severity = adjust_severity(severity);
  bool was_emitted = emit(severity, format, arguments);
  if (!was_emitted) return;
  if (severity == Severity::error) encountered_error_ = true;
  if (severity == Severity::warning) encountered_warning_ = true;
}

// A hackish way of finding '// @no-warn' comments.
// This approach is simple, but doesn't work all the time. Specifically, we might not
// report warnings in multi-line strings or toitdocs.
// Example:
// ```
// str := """
//    $(some-warning-operation)  // @no-warn
// """
// In this case the '// @no-warn' is part of the string and shouldn't be recognized.
bool Diagnostics::ends_with_no_warn_marker(const Source::Position& pos) {
  // See if the line ends with the NO_WARN_MARKER.
  auto manager = source_manager();
  if (manager == null) return false;
  auto source = manager->source_for_position(pos);
  auto text = source->text_at(pos);
  // Find the end of the line.
  size_t i = 0;
  while ((text[i] != '\n') && (text[i] != '\0'))
    i++;
  size_t marker_length = strlen(NO_WARN_MARKER);
  if (i < marker_length) return false;
  return strncmp(NO_WARN_MARKER, reinterpret_cast<const char*>(&text[i - marker_length]), marker_length) == 0;
}

void Diagnostics::report(Severity severity, Source::Range range, const char* format, va_list& arguments) {
  severity = adjust_severity(severity);
  if (severity == Severity::warning && ends_with_no_warn_marker(range.to())) {
    return;
  }
  bool was_emitted = emit(severity, range, format, arguments);
  if (!was_emitted) return;
  if (severity == Severity::error) encountered_error_ = true;
  if (severity == Severity::warning) encountered_warning_ = true;
}

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
  auto range = position_node->selection_range();
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
  report_warning(position_node->selection_range(), format, arguments);
  va_end(arguments);
}

void Diagnostics::report_note(const ast::Node* position_node, const char* format, ...) {
  auto range = position_node->selection_range();
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

bool CompilationDiagnostics::emit(Severity severity, const char* format, va_list& arguments) {
  auto target = print_on_stdout_ ? stdout : stderr;
  vfprintf(target, format, arguments);
  fputc('\n', target);
  return true;
}

void CompilationDiagnostics::start_group() {
  ASSERT(!in_group_);
  in_group_ = true;
  group_package_ = Package::invalid();
}

void CompilationDiagnostics::end_group() {
  in_group_ = false;
}

bool CompilationDiagnostics::emit(Severity severity,
                                  Source::Range range,
                                  const char* format,
                                  va_list& arguments) {
  auto from_location = source_manager()->compute_location(range.from());

  if (!show_package_warnings_) {
    Severity error_severity;
    Package error_package;
    if (in_group_) {
      // For groups, the first encountered error defines where the error comes
      // from. Subsequent diagnostics in the group use that package id.
      if (!group_package_.is_valid()) {
        group_package_ = from_location.source->package();
        group_severity_ = severity;
      }
      error_package = group_package_;
      error_severity = group_severity_;
    } else {
      error_package = from_location.source->package();
      error_severity = severity;
    }

    // If the package is not the entry package or a local path package,
    // skip reporting the warning/note.
    if (!error_package.is_path_package()) {
      switch (error_severity) {
        case Severity::error:
          break;
        case Severity::warning:
        case Severity::note:
          return false;
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

  auto out_target = print_on_stdout_ ? stdout : stderr;

  text_bold(stdout);
  if (absolute_path != null) {
    fprintf(out_target, "%s:%d:%d: ", error_path.c_str(), line_number, column_number);
  }
  switch (severity) {
    case Severity::warning:
      color_fun = &text_magenta;
      (*color_fun)(out_target);
      fprintf(out_target, "warning: ");
      break;
    case Severity::error:
      color_fun = &text_red;
      (*color_fun)(out_target);
      fprintf(out_target, "error: ");
      break;
    case Severity::note:
      color_fun = &text_green;
      (*color_fun)(out_target);
      fprintf(out_target, "note: ");
      break;
  }
  reset_colors(out_target);
  vfprintf(out_target, format, arguments);
  fputc('\n', out_target);

  // Print the source line.

  int index = line_offset;
  while (true) {
    int c = source[index++];
    if (c == 0 || is_newline(c)) break;
    fputc(c, out_target);
  }
  fputc('\n', out_target);

  // Skip over Windows newline.
  if (source[index - 1] == '\r' && source[index] == '\n') index++;

  // Print the `^~~~` at the correct location.

  (*color_fun)(out_target);
  index = line_offset;
  while (index < offset_in_source) {
    int c = source[index];
    // Keep tabs, to make it more likely that the ^ aligns correctly.
    fputc(c == '\t' ? '\t' : ' ', out_target);
    // UTF-8 multi-byte sequences are just treated like one character.
    index += Utils::bytes_in_utf_8_sequence(c);
  }
  fprintf(out_target, "^");
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
      fprintf(out_target, "~");
    }
  }
  fprintf(out_target, "\n");
  reset_colors(out_target);
  return true;
}

bool LanguageServerAnalysisDiagnostics::emit(Severity severity, const char* format, va_list& arguments) {
  lsp()->diagnostics()->emit(severity, format, arguments);
  return true;
}

bool LanguageServerAnalysisDiagnostics::emit(Severity severity,
                                             Source::Range range,
                                             const char* format,
                                             va_list& arguments) {
  lsp()->diagnostics()->emit(severity,
                             range_to_lsp_location(range, source_manager()),
                             format,
                             arguments);
  return true;
}

void LanguageServerAnalysisDiagnostics::start_group() {
  lsp()->diagnostics()->start_group();
}

void LanguageServerAnalysisDiagnostics::end_group() {
  lsp()->diagnostics()->end_group();
}

} // namespace toit::compiler
} // namespace toit

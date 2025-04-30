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

#pragma once

#include <string>

#include "../top.h"

#include "sources.h"

namespace toit {
namespace compiler {

class Lsp;

namespace ast {
class Node;
}

class Diagnostics {
 public:
  enum class Severity {
    error,
    warning,
    note,
  };

  // TODO(florian): this feels hackish...
  virtual bool should_report_missing_main() const = 0;

  void report(Severity severity, const char* format, va_list& arguments);
  void report(Severity severity, Source::Range range, const char* format, va_list& arguments);

  void report_error(const char* format, ...);
  void report_error(const char* format, va_list& arguments);
  void report_error(Source::Range range, const char* format, va_list& arguments);
  void report_error(Source::Range range, const char* format, ...);
  void report_error(const ast::Node* position_node, const char* format, ...);

  void report_warning(const char* format, ...);
  void report_warning(const char* format, va_list& arguments);
  void report_warning(Source::Range range, const char* format, va_list& arguments);
  void report_warning(Source::Range range, const char* format, ...);
  void report_warning(const ast::Node* position_node, const char* format, ...);

  void report_note(const char* format, ...);
  void report_note(const char* format, va_list& arguments);
  void report_note(Source::Range range, const char* format, va_list& arguments);
  void report_note(Source::Range range, const char* format, ...);
  void report_note(const ast::Node* position_node, const char* format, ...);

  virtual void start_group() {}
  virtual void end_group() {}

  bool encountered_error() const {
    return encountered_error_;
  }

  bool encountered_warning() const {
    return encountered_warning_;
  }

  SourceManager* source_manager() { return source_manager_; }

  void report_location(Source::Range range, const char* prefix);

 public:  // Public only for forwarding.
  /// Emits the diagnostic.
  /// Returns false, if the diagnostic is quelched (for example a warning for a different package).
  /// Returns true, otherwise.
  virtual bool emit(Severity severity, const char* format, va_list& arguments) = 0;
  virtual bool emit(Severity severity, Source::Range range, const char* format, va_list& arguments) = 0;

 protected:
  explicit Diagnostics(SourceManager* source_manager)
      : source_manager_(source_manager), encountered_error_(false), encountered_warning_(false) {}

  void set_encountered_error(bool value) {
    encountered_error_ = value;
  }

  void set_encountered_warning(bool value) {
    encountered_warning_ = value;
  }

  virtual Severity adjust_severity(Severity severity) { return severity; }

 private:
  SourceManager* source_manager_;
  bool encountered_error_;
  bool encountered_warning_;


  bool ends_with_no_warn_marker(const Source::Position& pos);
};

class CompilationDiagnostics : public Diagnostics {
 public:
  explicit CompilationDiagnostics(SourceManager* source_manager,
                                  bool show_package_warnings,
                                  bool print_on_stdout)
      : Diagnostics(source_manager)
      , show_package_warnings_(show_package_warnings)
      , print_on_stdout_(print_on_stdout) {}

  bool should_report_missing_main() const { return true; }

  void start_group();
  void end_group();

 protected:
  bool emit(Severity severity, const char* format, va_list& arguments);
  bool emit(Severity severity, Source::Range range, const char* format, va_list& arguments);

 private:
  bool show_package_warnings_;
  bool print_on_stdout_;
  bool in_group_ = false;
  Package group_package_;
  Severity group_severity_;
};

class AnalysisDiagnostics : public CompilationDiagnostics {
 public:
  explicit AnalysisDiagnostics(SourceManager* source_manager,
                               bool show_package_warnings,
                               bool print_on_stdout)
      : CompilationDiagnostics(source_manager, show_package_warnings, print_on_stdout) {}

  bool should_report_missing_main() const { return false; }
};

class LanguageServerAnalysisDiagnostics : public Diagnostics {
 public:
  explicit LanguageServerAnalysisDiagnostics(SourceManager* source_manager, Lsp* lsp)
      : Diagnostics(source_manager)
      , lsp_(lsp) {}

  bool should_report_missing_main() const { return false; }

  void start_group();
  void end_group();

 protected:
  bool emit(Severity severity, const char* format, va_list& arguments);
  bool emit(Severity severity, Source::Range range, const char* format, va_list& arguments);

  Lsp* lsp() { return lsp_; }

 private:
  Lsp* lsp_;
};

class NullDiagnostics : public Diagnostics {
 public:
  explicit NullDiagnostics(SourceManager* source_manager)
      : Diagnostics(source_manager) {}

  /// This constructor is used, when the null-diagnostic temporarily shadows an
  /// existing diagnostics.
  explicit NullDiagnostics(Diagnostics* other) : Diagnostics(null) {
    set_encountered_error(other->encountered_error());
  }

  bool should_report_missing_main() const { return false; }

  void start_group() {}
  void end_group() {}

 protected:
  // We return true for the 'emit' methods, so that asserts that test whether we encountered errors
  // still work.
  bool emit(Severity severity, const char* format, va_list& arguments) { return true; }
  bool emit(Severity severity, Source::Range range, const char* format, va_list& arguments) { return true; }
};

} // namespace toit::compiler
} // namespace toit

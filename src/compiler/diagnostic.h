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

  void report(Severity severity, const char* format, va_list& arguments) {
    severity = adjust_severity(severity);
    if (severity == Severity::error) _encountered_error = true;
    if (severity == Severity::warning) _encountered_warning = true;
    emit(severity, format, arguments);
  }
  void report(Severity severity, Source::Range range, const char* format, va_list& arguments) {
    severity = adjust_severity(severity);
    if (severity == Severity::error) _encountered_error = true;
    if (severity == Severity::warning) _encountered_warning = true;
    emit(severity, range, format, arguments);
  }

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

  virtual void start_group() { }
  virtual void end_group() { }

  bool encountered_error() const {
    return _encountered_error;
  }

  bool encountered_warning() const {
    return _encountered_warning;
  }

  SourceManager* source_manager() { return _source_manager; }

  void report_location(Source::Range range, const char* prefix);


 public:  // Public only for forwarding.
  virtual void emit(Severity severity, const char* format, va_list& arguments) = 0;
  virtual void emit(Severity severity, Source::Range range, const char* format, va_list& arguments) = 0;

 protected:
  explicit Diagnostics(SourceManager* source_manager)
      : _source_manager(source_manager), _encountered_error(false), _encountered_warning(false) { }

  void set_encountered_error(bool value) {
    _encountered_error = value;
  }

  void set_encountered_warning(bool value) {
    _encountered_warning = value;
  }

  virtual Severity adjust_severity(Severity severity) { return severity; }

 private:
  SourceManager* _source_manager;
  bool _encountered_error;
  bool _encountered_warning;
};

class CompilationDiagnostics : public Diagnostics {
 public:
  explicit CompilationDiagnostics(SourceManager* source_manager, bool show_package_warnings)
      : Diagnostics(source_manager)
      , _show_package_warnings(show_package_warnings) {}

  bool should_report_missing_main() const { return true; }

  void start_group();
  void end_group();

 protected:
  void emit(Severity severity, const char* format, va_list& arguments);
  void emit(Severity severity, Source::Range range, const char* format, va_list& arguments);

 private:
  bool _show_package_warnings;
  bool _in_group = false;
  std::string _group_package_id;
  Severity _group_severity;
};

class AnalysisDiagnostics : public CompilationDiagnostics {
 public:
  explicit AnalysisDiagnostics(SourceManager* source_manager, bool show_package_warnings)
      : CompilationDiagnostics(source_manager, show_package_warnings) {}

  bool should_report_missing_main() const { return false; }
};

class LanguageServerAnalysisDiagnostics : public Diagnostics {
 public:
  explicit LanguageServerAnalysisDiagnostics(SourceManager* source_manager)
      : Diagnostics(source_manager) {}

  bool should_report_missing_main() const { return false; }

  void start_group();
  void end_group();

 protected:
  void emit(Severity severity, const char* format, va_list& arguments);
  void emit(Severity severity, Source::Range range, const char* format, va_list& arguments);
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

  void start_group() { }
  void end_group() { }

 protected:
  void emit(Severity severity, const char* format, va_list& arguments) { }
  void emit(Severity severity, Source::Range range, const char* format, va_list& arguments) { }
};

} // namespace toit::compiler
} // namespace toit

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

#include "ast.h"
#include "backend.h"
#include "byte_gen.h"
#include "ir.h"
#include "sources.h"
#include "windows.h"

#include "../vm.h"
#include "../snapshot_bundle.h"

#include <vector>
#include <string>

namespace toit {

class Program;

namespace compiler {

class DispatchTable;
class Parser;
class ProgramBuilder;
class Diagnostics;
class SourceMapper;
class SymbolCanonicalizer;

struct PipelineConfiguration;

class Compiler {
 public:
  enum class DepFormat {
    none,
    plain,
    ninja,
  };

  struct Configuration {
    /// The path to a file where to write the dependencies.
    /// Optional (may be null).
    const char* dep_file;
    /// The format of the dependencies.
    DepFormat dep_format;
    /// The path to the project root.
    /// Optional (may be null).
    const char* project_root;
    /// Whether compilation should continue after encountering errors.
    bool force;
    /// Whether warnings should be treated like errors.
    bool werror;
    /// Whether to show warnings in packages.
    bool show_package_warnings;
  };

  Compiler();
  ~Compiler();

  /// Starts the compiler in language-server mode.
  ///
  /// The compiler reads the requested feature from stdin and dispatches
  /// accordingly.
  ///
  /// This mode does not run the program or generates any snapshots. It is
  /// intended to be used as the backend of a language server, and the
  /// generated information is not intended to be read by humans.
  void language_server(const Configuration& config);

  /// Analyzes the given source.
  ///
  /// This mode does not run the program or generates any snapshots. It simply
  /// prints out all found errors.
  void analyze(List<const char*> source_paths,
               const Configuration& config);

  /// Compiles the given program.
  ///
  /// The parameters [source_path] and [direct_script] are mutually exclusive.
  /// If one is given, the other one must be null.
  SnapshotBundle compile(const char* source_path,
                         const char* direct_script,
                         char** snapshot_args,
                         const char* out_path,
                         const Configuration& config);

 private:
  VM _vm;  // Needed to support allocation of program structures.

  /// Analyzes the given sources.
  ///
  /// This mode does not run the program or generates any snapshots. It simply
  /// prints out all found errors.
  void lsp_analyze(List<const char*> source_paths,
                   const PipelineConfiguration& configuration);

  /// Completes the identifier at the given location.
  ///
  /// This mode does not run the program or generates any snapshots. It simply
  /// prints out the found completions.
  void lsp_complete(const char* source_path,
                    int line_number,
                    int column_number,
                    const PipelineConfiguration& configuration);

  /// Finds the definition of the identifier at the given location.
  ///
  /// This mode does not run the program or generates any snapshots. It simply
  /// prints out the found location.
  void lsp_goto_definition(const char* source_path,
                           int line_number,
                           int column_number,
                           const PipelineConfiguration& configuration);

  /// Compiles the given program and sends the snapshot to the server.
  void lsp_snapshot(const char* source_path,
                    const PipelineConfiguration& configuration);

  /// Emits semantic tokens for the given source_path.
  void lsp_semantic_tokens(const char* source_path,
                           const PipelineConfiguration& configuration);

  /// Compiles the given [source_path] into a source bundle.
  SnapshotBundle compile(const char* source_path,
                         const PipelineConfiguration& configuration);
};

} // namespace toit::compiler
} // namespace toit

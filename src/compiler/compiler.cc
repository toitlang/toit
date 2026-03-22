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

#include "../top.h"

#include <errno.h>
#ifdef TOIT_POSIX
#include <sys/param.h>
#include <sys/wait.h>
#endif
#include <string>
#include <ctype.h>
#include <limits.h>
#include <unistd.h>
#include <stdio.h>
#include <fcntl.h>

#include "compiler.h"
#include "diagnostic.h"
#include "definite.h"
#include "dep_writer.h"
#include "dispatch_table.h"
#include "filesystem_hybrid.h"
#include "filesystem_local.h"
#include "filesystem_lsp.h"
#include "lambda.h"
#include "list.h"
#include "lsp/lsp.h"
#include "lsp/completion.h"
#include "lsp/goto_definition.h"
#include "lsp/rename.h"
#include "lsp/fs_connection_socket.h"
#include "lsp/fs_protocol.h"
#include "lsp/multiplex_stdout.h"
#include "lock.h"
#include "map.h"
#include "mixin.h"
#include "monitor.h"
#include "optimizations/optimizations.h"
#include "parser.h"
#include "propagation/type_database.h"
#include "resolver.h"
#include "resolver_scope.h"
#include "../snapshot_bundle.h"
#include "stubs.h"
#include "symbol_canonicalizer.h"
#include "token.h"
#include "tree.h"
#include "tree_roots.h"
#include "type_check.h"
#include "util.h"

#include "../objects_inline.h"
#include "../snapshot.h"
#include "../flags.h"
#include "../utils.h"

#include "third_party/semver/semver.h"

namespace toit {
namespace compiler {

const int ENTRY_UNIT_INDEX = 0;
const int CORE_UNIT_INDEX = 1;

struct PipelineConfiguration {
  const char* out_path;
  const char* dep_file;
  Compiler::DepFormat dep_format;

  const char* project_root;

  Filesystem* filesystem;
  SourceManager* source_manager;
  Diagnostics* diagnostics;
  Lsp* lsp;

  /// Whether to continue compiling after having encountered an error (if possible).
  bool force;
  /// Whether warnings should be treated like errors.
  bool werror;
  bool parse_only;
  bool is_for_analysis;
  bool is_for_dependencies;
  /// Optimization level.
  int optimization_level;
};

class Pipeline {
 public:
  struct Result {
    uint8* snapshot;
    int snapshot_size;
    uint8* source_map_data;
    int source_map_size;

    bool is_valid() const { return snapshot != null; }

    void free_all() {
      free(snapshot);
      snapshot = null;
      free(source_map_data);
      source_map_data = null;
    }

    static Result invalid() {
      return {
        .snapshot = null,
        .snapshot_size = 0,
        .source_map_data = null,
        .source_map_size = 0,
      };
    }
  };

  explicit Pipeline(const PipelineConfiguration& configuration)
      : configuration_(configuration) {}

  Result run(List<const char*> source_paths, bool propagate);

 protected:
  virtual Source* _load_file(const char* path, const PackageLock& package_lock);
  virtual ast::Unit* parse(Source* source);
  virtual void setup_lsp_selection_handler();
  virtual void post_resolve(Resolver* resolver, ir::Program* program);
  virtual void post_type_check();

  virtual List<const char*> adjust_source_paths(List<const char*> source_paths);
  virtual PackageLock load_package_lock(List<const char*> source_paths);

  SourceManager* source_manager() const { return configuration_.source_manager; }
  Diagnostics* diagnostics() const { return configuration_.diagnostics; }
  SymbolCanonicalizer* symbol_canonicalizer() { return &symbols_; }
  Filesystem* filesystem() const { return configuration_.filesystem; }
  Lsp* lsp() { return configuration_.lsp; }
  // The toitdoc registry is filled during the resolution stage.
  ToitdocRegistry* toitdocs() { return &toitdoc_registry_; }


 private:
  PipelineConfiguration configuration_;
  SymbolCanonicalizer symbols_;
  ToitdocRegistry toitdoc_registry_;

  ast::Unit* _parse_source(Source* source);

  Source* _load_import(ast::Unit* unit,
                       ast::Import* import,
                       const PackageLock& package_lock);
  std::vector<ast::Unit*> _parse_units(List<const char*> source_paths,
                                       const PackageLock& package_lock);
  ir::Program* resolve(const std::vector<ast::Unit*>& units,
                       int entry_unit_index,
                       int core_unit_index,
                       bool quiet = false);
  void check_types_and_deprecations(ir::Program* program, bool quiet = false);
};


class LanguageServerPipeline : public Pipeline {
 public:
  enum class Kind {
    analyze,
    semantic_tokens,
    completion,
    goto_definition,
    find_references,
    prepare_rename,
    hover,
  };

  LanguageServerPipeline(Kind kind,
                         const PipelineConfiguration& configuration)
      : Pipeline(configuration)
      , kind_(kind) {}

 protected:
  bool is_for_analysis() const { return true; }

  Kind kind() const { return kind_; }

 private:
  Kind kind_;
};

class LocationLanguageServerPipeline : public LanguageServerPipeline {
 public:
  LocationLanguageServerPipeline(Kind kind,
                                 const char* path,
                                 int line_number,   // 1-based
                                 int column_number, // 1-based
                                 const PipelineConfiguration& configuration)
      : LanguageServerPipeline(kind, configuration)
      , lsp_selection_path_(path)
      , line_number_(line_number)
      , column_number_(column_number) {}

 protected:
  ast::Unit* parse(Source* source);

  /// Whether the scanner should make keywords to identifiers if they are
  /// at the LSP-selection point.
  virtual bool is_lsp_selection_identifier() = 0;

  const char* lsp_selection_path_;
  int line_number_;
  int column_number_;
};

class CompletionPipeline : public LocationLanguageServerPipeline {
 public:
  CompletionPipeline(const char* completion_path,
                     int line_number,   // 1-based
                     int column_number, // 1-based
                     const PipelineConfiguration& configuration)
      : LocationLanguageServerPipeline(LanguageServerPipeline::Kind::completion,
                                       completion_path,
                                       line_number,
                                       column_number,
                                       configuration) {}

 protected:
  void setup_lsp_selection_handler();
  Source* _load_file(const char* path, const PackageLock& package_lock);

  bool is_lsp_selection_identifier() { return true; }

 private:
  CompletionHandler* handler() {
    return static_cast<CompletionHandler*>(lsp()->selection_handler());
  }

  friend class LocationLanguageServerPipeline;
};

class GotoDefinitionPipeline : public LocationLanguageServerPipeline {
 public:
  GotoDefinitionPipeline(const char* goto_definition_path,
                         int line_number,   // 1-based
                         int column_number, // 1-based
                         const PipelineConfiguration& configuration)
      : LocationLanguageServerPipeline(LanguageServerPipeline::Kind::goto_definition,
                                       goto_definition_path,
                                       line_number,
                                       column_number,
                                       configuration) {}

 protected:
  void setup_lsp_selection_handler();

  bool is_lsp_selection_identifier() { return false; }
};

class FindReferencesPipeline : public LocationLanguageServerPipeline {
 public:
  FindReferencesPipeline(const char* find_references_path,
                         int line_number,   // 1-based
                         int column_number, // 1-based
                         const PipelineConfiguration& configuration)
      : LocationLanguageServerPipeline(LanguageServerPipeline::Kind::find_references,
                                       find_references_path,
                                       line_number,
                                       column_number,
                                       configuration) {}

 protected:
  void setup_lsp_selection_handler() override;
  void post_resolve(Resolver* resolver, ir::Program* program) override;
  void post_type_check() override;

  bool is_lsp_selection_identifier() override { return false; }

 private:
  /// Emits all rename locations for [target] and exits (does not return).
  void emit_all_references(ir::Node* target, ir::Program* program,
                           UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast);

  // State saved during post_resolve for deferred use in post_type_check.
  // When the cursor is on a virtual call site, the target is not available
  // until after type checking (when the call_virtual callback fires).
  ir::Program* program_ = null;
  UnorderedMap<ir::Node*, ast::Node*> ir_to_ast_map_;

  // Show/export clause references collected from the resolver.
  // Each entry maps a resolved target definition to the source range
  // of the show/export identifier that references it.
  std::vector<Resolver::ShowExportReference> show_export_references_;
};

class PrepareRenamePipeline : public LocationLanguageServerPipeline {
 public:
  PrepareRenamePipeline(const char* path,
                        int line_number,   // 1-based
                        int column_number, // 1-based
                        const PipelineConfiguration& configuration)
      : LocationLanguageServerPipeline(LanguageServerPipeline::Kind::prepare_rename,
                                       path,
                                       line_number,
                                       column_number,
                                       configuration) {}

 protected:
  void setup_lsp_selection_handler() override;
  void post_resolve(Resolver* resolver, ir::Program* program) override;
  void post_type_check() override;

  bool is_lsp_selection_identifier() override { return false; }

 private:
  /// Emits the prepareRename response and exits.
  ///
  /// If [range_override] is valid, it is used instead of the target's own range.
  /// This is needed for named constructors/factories where the IR range points
  /// to the "constructor"/"factory" keyword but we want the name part (e.g., "bar").
  void emit_prepare_rename(ir::Node* target,
                           Source::Range range_override = Source::Range::invalid());
};

class HoverPipeline : public LocationLanguageServerPipeline {
 public:
  HoverPipeline(const char* hover_path,
                int line_number,   // 1-based
                int column_number, // 1-based
                const PipelineConfiguration& configuration)
      : LocationLanguageServerPipeline(LanguageServerPipeline::Kind::hover,
                                       hover_path,
                                       line_number,
                                       column_number,
                                       configuration) {}

 protected:
  void setup_lsp_selection_handler() override {
    lsp()->setup_hover_handler(source_manager(), toitdocs());
  }

  void post_resolve(Resolver* resolver, ir::Program* program) override {
    if (lsp() == null || !lsp()->has_selection_handler()) return;
    auto* handler = static_cast<HoverHandler*>(lsp()->selection_handler());
    handler->finalize();
  }

  void post_type_check() override {
    if (lsp() == null || !lsp()->has_selection_handler()) return;
    auto* handler = static_cast<HoverHandler*>(lsp()->selection_handler());
    handler->finalize();
  }

  bool is_lsp_selection_identifier() override { return false; }
};

class LineReader {
 public:
  explicit LineReader(FILE* file) : file_(file), line_(null), line_size_(0) {}
  ~LineReader() {
    free(line_);
  }

 /// Returns the next line without terminating `\n`.
 ///
 /// The returned string has been allocated with malloc.
 char* next(const char* kind, bool must_be_non_empty = true) {
  auto characters_read = getline(&line_, &line_size_, file_);
  if (characters_read <= (must_be_non_empty ? 1 : 0)) {
    FATAL("LANGUAGE SERVER ERROR - Expected %s", kind);
  }
  line_[characters_read - 1] = '\0';  // Remove trailing newline.
  return strdup(line_);
 }

 int next_int(const char* kind) {
  auto characters_read = getline(&line_, &line_size_, file_);
  if (characters_read <= 1) {
    FATAL("LANGUAGE SERVER ERROR - Expected %s", kind);
  }
  return atoi(line_);
 }

 private:
  FILE* file_;
  char* line_;
  size_t line_size_;
};

Compiler::Compiler() {
  // Compiler can use throwing new, which causes null pointer crashes on out-of-memory.
  toit::throwing_new_allowed = true;
}

Compiler::~Compiler() {
  toit::throwing_new_allowed = false;
}

void Compiler::language_server(const Compiler::Configuration& compiler_config) {
  // The language server uses a strict protocol over stdin/stdout, so switching
  // to binary mode on windows.
#ifdef TOIT_WINDOWS
  setmode(fileno(stdin), O_BINARY);
  setmode(fileno(stdout), O_BINARY);
#endif
  LineReader reader(stdin);
  const char* port = reader.next("port");

  Filesystem* fs = null;
  LspFsProtocol* fs_protocol = null;
  LspFsConnection* connection = null;
  LspWriter* writer = null;
  if (strcmp("-1", port) == 0) {
    fs = _new FilesystemLocal();
    writer = new LspWriterStdout();
  } else {
    if (strcmp("-2", port) == 0) {
      // Multiplex the FS protocol and the LSP output over stdout/stdin.
      connection = _new LspFsConnectionMultiplexStdout();
      writer = _new LspWriterMultiplexStdout();
    } else {
      // Communicate over a socket for the filesystem, and over stdout
      // for the LSP output.
      connection = _new LspFsConnectionSocket(port);
      writer = new LspWriterStdout();
    }
    fs_protocol = _new LspFsProtocol(connection);
    fs = _new FilesystemLsp(fs_protocol);
  }
  LspProtocol* lsp_protocol = new LspProtocol(writer);

  // We generally don't explicitly keep track of memory, but here we might need
  // to release resources.
  Defer del { [&] {
      delete fs;
      delete fs_protocol;
      delete connection;
      delete writer;
      delete lsp_protocol;
    }
  };

  Lsp lsp(lsp_protocol);

  const char* mode = reader.next("mode");
  SourceManager source_manager(fs);
  PipelineConfiguration configuration = {
    .out_path = null,
    .dep_file = null,
    .dep_format = DepFormat::none,
    .project_root = compiler_config.project_root,
    .filesystem = fs,
    .source_manager = &source_manager,
    .diagnostics = null,  // Needs to be set later.
    .lsp = &lsp,
    .force = compiler_config.force,
    .werror = compiler_config.werror,
    .parse_only = false,
    .is_for_analysis = true,
    .is_for_dependencies = false,
    .optimization_level = compiler_config.optimization_level,
  };

  if (strcmp("ANALYZE", mode) == 0) {
    int path_count = reader.next_int("path count");
    if (path_count < 1) {
      FATAL("LANGUAGE SERVER ERROR - analyze must have at least one source");
    }
    auto source_paths = ListBuilder<const char*>::allocate(path_count);
    for (int i = 0; i < path_count; i++) {
      source_paths[i] = strdup(reader.next("path"));
    }
    LanguageServerAnalysisDiagnostics diagnostics(&source_manager, &lsp);
    configuration.diagnostics = &diagnostics;
    lsp.set_needs_summary(true);
    lsp_analyze(source_paths, configuration);
  } else if (strcmp("PARSE", mode) == 0) {
    int path_count = reader.next_int("path count");
    if (path_count < 1) {
      FATAL("LANGUAGE SERVER ERROR - parse must have at least one source");
    }
    auto source_paths = ListBuilder<const char*>::allocate(path_count);
    for (int i = 0; i < path_count; i++) {
      source_paths[i] = strdup(reader.next("path"));
    }

    NullDiagnostics diagnostics(&source_manager);
    configuration.diagnostics = &diagnostics;
    configuration.parse_only = true;
    lsp.set_needs_summary(false);
    lsp_analyze(source_paths, configuration);
  } else if (strcmp("SNAPSHOT BUNDLE", mode) == 0) {
    const char* path = reader.next("path");
    NullDiagnostics diagnostics(&source_manager);
    configuration.diagnostics = &diagnostics;
    configuration.is_for_analysis = false;
    lsp_snapshot(path, configuration);
  } else if (strcmp("SEMANTIC TOKENS", mode) == 0) {
    const char* path = reader.next("path");
    NullDiagnostics diagnostics(&source_manager);
    configuration.diagnostics = &diagnostics;
    configuration.is_for_analysis = true;
    lsp_semantic_tokens(path, configuration);
  } else {
    const char* path = reader.next("path");
    // We generally use 1-based line/column numbers.
    int line_number = 1 + reader.next_int("line number (0-based)");
    int column_number = 1 + reader.next_int("column number (0-based)");
    NullDiagnostics diagnostics(&source_manager);
    configuration.diagnostics = &diagnostics;
    if (strcmp("COMPLETE", mode) == 0) {
      lsp_complete(path, line_number, column_number, configuration);
    } else if (strcmp("GOTO DEFINITION", mode) == 0) {
      lsp_goto_definition(path, line_number, column_number, configuration);
    } else if (strcmp("HOVER", mode) == 0) {
      lsp_hover(path, line_number, column_number, configuration);
    } else if (strcmp("REFERENCES", mode) == 0) {
      const char* entry_path = reader.next("entry path");
      lsp_references(path, entry_path, line_number, column_number, configuration);
    } else if (strcmp("PREPARE RENAME", mode) == 0) {
      const char* entry_path = reader.next("entry path");
      lsp_prepare_rename(path, entry_path, line_number, column_number, configuration);
    } else {
      FATAL("LANGUAGE SERVER ERROR - Mode not recognized: '%s'", mode);
    }
  }
}

void Compiler::lsp_complete(const char* source_path,
                            int line_number,
                            int column_number,
                            const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  CompletionPipeline pipeline(source_path, line_number, column_number, configuration);
  pipeline.run(ListBuilder<const char*>::build(source_path), false);
}

void Compiler::lsp_goto_definition(const char* source_path,
                                   int line_number,
                                   int column_number,
                                   const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  GotoDefinitionPipeline pipeline(source_path, line_number, column_number, configuration);

  pipeline.run(ListBuilder<const char*>::build(source_path), false);
}

void Compiler::lsp_references(const char* source_path,
                              const char* entry_path,
                              int line_number,
                              int column_number,
                              const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  // source_path: the file containing the cursor (for LspSelection injection).
  // entry_path: the compilation entry point (may differ for cross-file rename).
  FindReferencesPipeline pipeline(source_path, line_number, column_number, configuration);
  pipeline.run(ListBuilder<const char*>::build(entry_path), false);
}

void Compiler::lsp_prepare_rename(const char* source_path,
                                  const char* entry_path,
                                  int line_number,
                                  int column_number,
                                  const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  PrepareRenamePipeline pipeline(source_path, line_number, column_number, configuration);
  pipeline.run(ListBuilder<const char*>::build(entry_path), false);
}

void Compiler::lsp_hover(const char* source_path,
                         int line_number,
                         int column_number,
                         const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  HoverPipeline pipeline(source_path, line_number, column_number, configuration);

  pipeline.run(ListBuilder<const char*>::build(source_path), false);
}

void Compiler::lsp_analyze(List<const char*> source_paths,
                           const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  LanguageServerPipeline pipeline(LanguageServerPipeline::Kind::analyze, configuration);
  pipeline.run(source_paths, false);
}

void Compiler::lsp_snapshot(const char* source_path,
                            const PipelineConfiguration& configuration) {
  Flags::no_fork = true; // No need to fork the compiler when running in LSP mode.
  SnapshotBundle bundle = compile(source_path, configuration);
  if (!bundle.is_valid()) {
    configuration.lsp->snapshot()->fail();
    return;
  }
  configuration.lsp->snapshot()->emit(bundle);
  free(bundle.buffer());
}

void Compiler::lsp_semantic_tokens(const char* source_path,
                                   const PipelineConfiguration& configuration) {
  configuration.lsp->set_should_emit_semantic_tokens(true);
  ASSERT(configuration.diagnostics != null);
  LanguageServerPipeline pipeline(LanguageServerPipeline::Kind::semantic_tokens, configuration);
  pipeline.run(ListBuilder<const char*>::build(source_path), false);
}

static bool _sorted_by_inheritance(List<ir::Class*> classes) {
  UnorderedSet<ir::Class*> seen_mixins;
  std::vector<ir::Class*> super_hierarchy;
  ir::Class* current_super = null;
  ir::Class* last = null;
  for (auto klass : classes) {
    if (klass->is_mixin()) {
      // For mixins we don't require subclasses to be in depth-first order.
      // We just require that all its parents have already been seen.
      if (klass->super() != null && !seen_mixins.contains(klass->super())) return false;
      for (auto mixin : klass->mixins()) {
        if (!seen_mixins.contains(mixin)) return false;
      }
      seen_mixins.insert(klass);
      continue;
    }

    // Check that the hierarchy is depth-first.
    // Directly after a class must be its first subclass.
    if (klass->super() == current_super) {
      // Do nothing.
    } else if (klass->super() == last) {
      // The 'last' has subclasses.
      super_hierarchy.push_back(current_super);
      current_super = last;
    } else {
      // A subclass is done. Walk up the chain to find again the super of this
      // class.
      while (!super_hierarchy.empty() && current_super != klass->super()) {
        current_super = super_hierarchy.back();
        super_hierarchy.pop_back();
      }
      if (current_super != klass->super()) return false;
    }
    last = klass;
  }
  return true;
}

bool read_from_pipe(int fd, void* buffer, int requested_bytes) {
  do {
    int read_count = read(fd, buffer, requested_bytes);
    if (read_count <= 0) {
      if (read_count == -1) {
        perror("read_from_pipe");
      }
      return false;
    }
    requested_bytes -= read_count;
    buffer = static_cast<char*>(buffer) + read_count;
  } while(requested_bytes > 0);
  return true;
}

void Compiler::analyze(List<const char*> source_paths,
                       const Compiler::Configuration& compiler_config,
                       bool for_dependencies) {
  // We accept '/' paths on Windows as well.
  // For simplicity (and consistency) switch to localized ones in the compiler.
  source_paths = FilesystemLocal::to_local_path(source_paths);
  bool single_source = source_paths.length() == 1;
  FilesystemHybrid fs(single_source ? source_paths[0] : null);
  SourceManager source_manager(&fs);
  AnalysisDiagnostics analysis_diagnostics(&source_manager,
                                           compiler_config.show_package_warnings,
                                           compiler_config.print_diagnostics_on_stdout);
  NullDiagnostics null_diagnostics(&source_manager);
  Diagnostics* diagnostics = (Flags::migrate_dash_ids || for_dependencies)
      ? static_cast<Diagnostics*>(&null_diagnostics)
      : static_cast<Diagnostics*>(&analysis_diagnostics);
  const char* dep_file = (for_dependencies && compiler_config.dep_file == null)
      ? "-"
      : compiler_config.dep_file;
  DepFormat dep_format = (for_dependencies && compiler_config.dep_format == DepFormat::none)
      ? DepFormat::list
      : compiler_config.dep_format;
  PipelineConfiguration configuration = {
    .out_path = null,
    .dep_file = dep_file,
    .dep_format = dep_format,
    .project_root = compiler_config.project_root,
    .filesystem = &fs,
    .source_manager = &source_manager,
    .diagnostics = diagnostics,
    .lsp = null,
    .force = compiler_config.force,
    .werror = compiler_config.werror,
    .parse_only = false,
    .is_for_analysis = !for_dependencies,
    .is_for_dependencies = for_dependencies,
    .optimization_level = compiler_config.optimization_level,
  };
  Pipeline pipeline(configuration);
  pipeline.run(source_paths, false);
}

#ifdef TOIT_POSIX

static Pipeline::Result receive_pipeline_result(int read_fd) {
  int snapshot_size = -1;
  uint8* snapshot = null;
  int source_map_size = -1;
  uint8* source_map_data = null;

  if (!read_from_pipe(read_fd, &snapshot_size, sizeof(int))) return Pipeline::Result::invalid();
  snapshot = unvoid_cast<uint8*>(malloc(snapshot_size));
  if (!read_from_pipe(read_fd, snapshot, snapshot_size)) FATAL("Incomplete data");
  if (!read_from_pipe(read_fd, &source_map_size, sizeof(int))) FATAL("Incomplete data");
  source_map_data = unvoid_cast<uint8*>(malloc(source_map_size));
  if (!read_from_pipe(read_fd, source_map_data, source_map_size)) FATAL("Incomplete data");

  ASSERT(snapshot_size != -1);
  ASSERT(source_map_size != -1);
  return {
    .snapshot = snapshot,
    .snapshot_size = snapshot_size,
    .source_map_data = source_map_data,
    .source_map_size = source_map_size,
  };
}

static void send_pipeline_result(int write_fd, const Pipeline::Result& pipeline_result) {
  auto write_to_fd = [&] (const void* data, size_t size) {
    while (size > 0) {
      auto written = write(write_fd, data, size);
      if (written == -1 && errno == EAGAIN) continue;
      if (written == -1) {
        FATAL("Couldn't write to pipe");
      }
      data = void_cast(unvoid_cast<const char*>(data) + written);
      size -= written;
    }
  };

  write_to_fd(&pipeline_result.snapshot_size, sizeof(int));
  write_to_fd(pipeline_result.snapshot, pipeline_result.snapshot_size);
  write_to_fd(&pipeline_result.source_map_size, sizeof(int));
  write_to_fd(pipeline_result.source_map_data, pipeline_result.source_map_size);
}

static void wait_for_child(int cpid, Diagnostics* diagnostics) {
  int status;
  while (true) {
    int result = waitpid(cpid, &status, 0);
    if (result == -1) {
      if (errno != EINTR) {
        perror("wait");
        exit(EXIT_FAILURE);
      }
    } else {
      break;
    }
  }
  if (WIFEXITED(status)) {
    int exit_code = WEXITSTATUS(status);
    if (exit_code != 0) exit(exit_code);
    // Otherwise we were successful and all the data should be correct.
  } else {
    if (!diagnostics->encountered_error()) {
      diagnostics->start_group();
      diagnostics->report_error("Compilation failed");
      if (WCOREDUMP(status)) {
        diagnostics->report_note("Core dumped");
      } else if (WIFSIGNALED(status)) {
        diagnostics->report_note("Received signal %d", WTERMSIG(status));
      } else if (WIFSTOPPED(status)) {
        diagnostics->report_note("Stopped by signal %d", WSTOPSIG(status));
      }
      diagnostics->end_group();
    }
    exit(-1);
  }
}

#endif

static const uint8* wrap_direct_script_expression(const char* direct_script, Diagnostics* diagnostics);

SnapshotBundle Compiler::compile(const char* source_path,
                                 const char* direct_script,
                                 const char* out_path,
                                 const Compiler::Configuration& compiler_config) {
  // We accept '/' paths on Windows as well.
  // For simplicity (and consistency) switch to localized ones in the compiler.
  source_path = FilesystemLocal::to_local_path(source_path);
  out_path = FilesystemLocal::to_local_path(out_path);
  FilesystemHybrid fs(source_path);
  SourceManager source_manager(&fs);
  CompilationDiagnostics diagnostics(&source_manager,
                                     compiler_config.show_package_warnings,
                                     compiler_config.print_diagnostics_on_stdout);

  if (direct_script != null) {
    const uint8* direct_script_file_content = wrap_direct_script_expression(direct_script, &diagnostics);
    // We should use the VIRTUAL_FILE_PREFIX constant from the SourceManager, but
    // it's a bit inconvenient to build the path, so we just verify that the prefix
    // is correct.
    source_path = "///<script>";
    ASSERT(SourceManager::is_virtual_file(source_path));
    fs.register_intercepted(source_path,
                            direct_script_file_content,
                            strlen(char_cast(direct_script_file_content)));
  }
  ASSERT(source_path != null);

  PipelineConfiguration configuration = {
    .out_path = out_path,
    .dep_file = compiler_config.dep_file,
    .dep_format = compiler_config.dep_format,
    .project_root = compiler_config.project_root,
    .filesystem = &fs,
    .source_manager = &source_manager,
    .diagnostics = &diagnostics,
    .lsp = null,
    .force = compiler_config.force,
    .werror = compiler_config.werror,
    .parse_only = false,
    .is_for_analysis = false,
    .is_for_dependencies = false,
    .optimization_level = compiler_config.optimization_level,
  };

  return compile(source_path, configuration);
}

SnapshotBundle Compiler::compile(const char* source_path,
                                 const PipelineConfiguration& configuration) {
  PipelineConfiguration main_configuration = configuration;

  auto source_paths = ListBuilder<const char*>::build(source_path);

  auto pipeline_main_result = Pipeline::Result::invalid();

  if (Flags::no_fork) {
    if (Flags::compiler_sandbox) {
      fprintf(stderr, "Can't specify separate compiler sandbox with no_fork option\n");
      exit(1);
    }
    Pipeline main_pipeline(main_configuration);
    pipeline_main_result = main_pipeline.run(source_paths, Flags::propagate);
  } else {
#ifdef TOIT_POSIX
    int pipefd[2];
    if (pipe(pipefd) == -1) {
      perror("pipe");
      exit(EXIT_FAILURE);
    }
    int read_fd = pipefd[0];
    int write_fd = pipefd[1];

    pid_t cpid = fork();
    if (cpid == 0) {
      // The child.
      close(read_fd);

      Pipeline pipeline(main_configuration);
      auto pipeline_result = pipeline.run(source_paths, Flags::propagate);
      send_pipeline_result(write_fd, pipeline_result);
      close(write_fd);
      exit(0);
    }
    close(write_fd);  // Not needing that direction.
    pipeline_main_result = receive_pipeline_result(read_fd);
    close(read_fd);
    wait_for_child(cpid, main_configuration.diagnostics);
#else
    FATAL("fork not supported");
#endif
  }
  if (!pipeline_main_result.is_valid()) {
    pipeline_main_result.free_all();
    return SnapshotBundle::invalid();
  }
  SnapshotBundle result(List<uint8>(pipeline_main_result.snapshot,
                                    pipeline_main_result.snapshot_size),
                        List<uint8>(pipeline_main_result.source_map_data,
                                    pipeline_main_result.source_map_size));
  // The snapshot bundle copies all given data. It's thus safe to free
  //   the pipeline data.
  pipeline_main_result.free_all();
  return result;
}

/// Returns the offset in the source for the given line and column number.
/// The column_number is in UTF-16 and needs to be adjusted to UTF-8.
///
/// The line number should be 1-based.
/// The column number should be 1-based.
///
/// Aborts the program if the file is not big enough.
static int compute_source_offset(const uint8* source, int line_number, int utf16_column_number) {
  int offset = 0;
  int line = 1;  // The line number of the offset position.
  // Skip to the correct line first.
  while (line < line_number) {
    int c = source[offset++];
    if (c == '\0') {
      // Didn't find enough lines.
      UNREACHABLE();
    }
    if (c == 10 || c == 13) {
      int other = (c == 10) ? 13 : 10;
      if (source[offset] == other) offset++;
      line++;
    }
  }
  // Advance in the same line.
  //  [offset] is pointing to the first character of the line.
  // Note that we don't look whether we hit another new-line character. We
  //  just assume that the client sent us a correct request.
  // However, we need to convert the utf-16 column number to utf-8 offsets.
  // Also we don't want to accidentally access invalid memory.
  for (int i = 1; i < utf16_column_number; i++) {
    if (source[offset] == '\0') {
      // Didn't find enough characters.
      UNREACHABLE();
    }
    int nb_bytes = Utils::bytes_in_utf_8_sequence(source[offset]);
    offset += nb_bytes;
    // If the UTF-8 sequence takes more than 3 bytes, it is encoded as surrogate pair in UTF-16.
    if (nb_bytes > 3) i++;
  }
  return offset;
}

ast::Unit* Pipeline::parse(Source* source) {
  Scanner scanner(source, symbol_canonicalizer(), diagnostics());
  Parser parser(source, &scanner, diagnostics());
  return parser.parse_unit();
}

void Pipeline::setup_lsp_selection_handler() {
  // Do nothing.
}

void Pipeline::post_resolve(Resolver* resolver, ir::Program* program) {
  // Do nothing. Subclasses (like HoverPipeline) can override
  // to perform work after all modules have been resolved.
}

void Pipeline::post_type_check() {
  // Do nothing. Subclasses (like HoverPipeline) can override
  // to perform work after type checking completes.
}

ir::Program* Pipeline::resolve(const std::vector<ast::Unit*>& units,
                               int entry_unit_index,
                               int core_unit_index,
                               bool quiet) {
  // Resolve all units.
  NullDiagnostics null_diagnostics(this->diagnostics());
  Diagnostics* diagnostics = quiet ? &null_diagnostics : this->diagnostics();
  Resolver resolver(lsp(), source_manager(), diagnostics, &toitdoc_registry_);
  auto result = resolver.resolve(units,
                                 entry_unit_index,
                                 core_unit_index);
  // Call post_resolve while the resolver (and its ir_to_ast_map) is still alive.
  post_resolve(&resolver, result);
  return result;
}

void Pipeline::check_types_and_deprecations(ir::Program* program, bool quiet) {
  NullDiagnostics null_diagnostics(this->diagnostics());
  Diagnostics* diagnostics = quiet ? &null_diagnostics : this->diagnostics();
  ::toit::compiler::check_types_and_deprecations(program, configuration_.lsp, toitdocs(), diagnostics);
}

List<const char*> Pipeline::adjust_source_paths(List<const char*> source_paths) {
  auto fs_entry_path = filesystem()->entry_path();
  if (fs_entry_path != null) {
    // The filesystem can override the entry path.
    source_paths = ListBuilder<const char*>::build(fs_entry_path);
  }
  return source_paths;
}

PackageLock Pipeline::load_package_lock(const List<const char*> source_paths) {
  auto entry_path = source_paths.first();
  std::string lock_file;
  if (configuration_.project_root != null) {
    lock_file = find_lock_file_at(configuration_.project_root, filesystem());
  } else {
    lock_file = find_lock_file(entry_path, filesystem());
  }
  return PackageLock::read(lock_file,
                           entry_path,
                           source_manager(),
                           filesystem(),
                           diagnostics());
}

ast::Unit* LocationLanguageServerPipeline::parse(Source* source) {
  if (strcmp(source->absolute_path(), lsp_selection_path_) != 0) return Pipeline::parse(source);

  const uint8* text = source->text();
  int offset = compute_source_offset(text, line_number_, column_number_);

  if (kind() == LanguageServerPipeline::Kind::completion) {
    auto handler = static_cast<CompletionPipeline*>(this)->handler();
    // We only provide completions after a '-' if there isn't a space in
    // front of the '-', and if we don't have 'foo--'. That is, a '--'
    // without a space in front.
    if (offset >= 2 && text[offset - 1] == '-' &&
        (text[offset - 2] == ' ' || text[offset - 2] == '\n')) {
      handler->terminate();
    }
    if (offset >= 3 && text[offset - 1] == '-' && text[offset - 2] == '-' && text[offset - 3] != ' ') {
      handler->terminate();
    }
  }

  LspSource lsp_source(source, offset);
  Scanner scanner(&lsp_source, is_lsp_selection_identifier(), symbol_canonicalizer(), diagnostics());
  Parser parser(&lsp_source, &scanner, diagnostics());
  // The source of the unit is not the source we are giving to the scanner and parser.
  return parser.parse_unit(source);
}

Source* CompletionPipeline::_load_file(const char* path, const PackageLock& package_lock) {
  auto result = LocationLanguageServerPipeline::_load_file(path, package_lock);
  if (strcmp(path, lsp_selection_path_) != 0) return result;

  // Now that we have loaded the file that contains the LSP selection, extract
  // the prefix (if there is any), and the package it is from.

  auto package_id = package_lock.package_for(path, filesystem()).id();
  handler()->set_package_id(package_id);

  const uint8* text = result->text();
  int offset = compute_source_offset(text, line_number_, column_number_);
  int start_offset = offset;
  IdentifierValidator validator;
  validator.disable_start_check();
  while (true) {
    if (start_offset <= 0) break;
    auto peek = [&]() {
      if (offset == start_offset) return LSP_SELECTION_MARKER;
      return text[start_offset];
    };
    // Walk backwards as long as it's a valid identifier character.
    if (!validator.check_next_char(text[start_offset - 1], peek)) {
      break;
    }
    start_offset--;
  }

  if (start_offset == offset || !IdentifierValidator::is_identifier_start(text[start_offset])) {
    handler()->set_and_emit_prefix(Symbols::empty_string, result->range(start_offset, start_offset));
  } else {
    auto range = result->range(start_offset, offset);
    int len = offset - start_offset;
    auto dash_canonicalized = IdentifierValidator::canonicalize(&text[start_offset], len);
    auto canonicalized = symbol_canonicalizer()->canonicalize_identifier(dash_canonicalized, &dash_canonicalized[len]);
    if (canonicalized.kind == Token::Kind::IDENTIFIER) {
      handler()->set_and_emit_prefix(canonicalized.symbol, range);
    } else {
      handler()->set_and_emit_prefix(Token::symbol(canonicalized.kind), range);
    }
  }
  return result;
}

void CompletionPipeline::setup_lsp_selection_handler() {
  lsp()->setup_completion_handler(source_manager());
}

void GotoDefinitionPipeline::setup_lsp_selection_handler() {
  lsp()->setup_goto_definition_handler(source_manager());
}

void FindReferencesPipeline::setup_lsp_selection_handler() {
  lsp()->setup_find_references_handler(source_manager());
}

/// Finds the IR definition node at the given cursor position.
///
/// The LSP selection mechanism works by inserting a dot-marker at the cursor
/// position, which the resolver handles as a synthetic call expression. This
/// triggers handler callbacks (like `call_static`) at reference/usage sites.
/// However, at definition sites (e.g., `foo x:` or `my-global := 42`), there
/// is no call expression to resolve, so the handler callback is never invoked
/// and no target is captured.
///
/// This function provides a fallback for that case: it iterates the program's
/// top-level definitions (globals, methods, classes, and class fields) and
/// finds the one whose name range contains the cursor position.
static ir::Node* find_definition_at_cursor(ir::Program* program,
                                           SourceManager* source_manager,
                                           const char* cursor_path,
                                           int cursor_line,     // 1-based
                                           int cursor_column) { // 1-based
  // Checks whether the given range's start location matches the cursor.
  // Definition name ranges are typically short (a single identifier on one
  // line), so we check that the cursor line matches the start line and that
  // the cursor column falls between the start and end columns.
  auto range_contains_cursor = [&](Source::Range range) -> bool {
    if (!range.is_valid()) return false;
    auto from = source_manager->compute_location(range.from());
    if (!from.is_valid()) return false;
    if (strcmp(from.source->absolute_path(), cursor_path) != 0) return false;
    if (from.line_number != cursor_line) return false;
    auto to = source_manager->compute_location(range.to());
    // offset_in_line is 0-based; cursor_column is 1-based.
    int cursor_col_0 = cursor_column - 1;
    return cursor_col_0 >= from.offset_in_line && cursor_col_0 < to.offset_in_line;
  };

  // Check classes first — a default (synthesized) constructor or factory may
  // share its range with the class definition, and we want to return the
  // class rather than the constructor when the cursor is on the class name.
  for (auto* klass : program->classes()) {
    if (range_contains_cursor(klass->range())) return klass;
    for (auto* field : klass->fields()) {
      if (range_contains_cursor(field->range())) return field;
    }
    for (auto* method : klass->methods()) {
      if (range_contains_cursor(method->range())) return method;
    }
    for (auto* constructor : klass->unnamed_constructors()) {
      if (range_contains_cursor(constructor->range())) return constructor;
    }
    for (auto* factory : klass->factories()) {
      if (range_contains_cursor(factory->range())) return factory;
    }
    if (klass->statics() != null) {
      for (auto* node : klass->statics()->nodes()) {
        if (node->is_Method() && range_contains_cursor(node->as_Method()->range())) {
          return node;
        }
      }
    }
  }
  // Check globals (ir::Global is a subtype of ir::Method).
  for (auto* global : program->globals()) {
    if (range_contains_cursor(global->range())) return global;
  }
  // Check top-level methods (functions).
  for (auto* method : program->methods()) {
    if (range_contains_cursor(method->range())) return method;
  }
  // Check locals and parameters in method bodies.
  class DefinitionFinder : public ir::TraversingVisitor {
   public:
    DefinitionFinder(std::function<bool(Source::Range)> range_contains_cursor)
        : range_contains_cursor_(std::move(range_contains_cursor)) {}

    void visit_Method(ir::Method* node) override {
      for (auto parameter : node->parameters()) {
        if (range_contains_cursor_(parameter->range())) {
          result_ = parameter;
          return;
        }
      }
      ir::TraversingVisitor::visit_Method(node);
    }

    void visit_Sequence(ir::Sequence* node) override {
      if (result_ != null) return;
      ir::TraversingVisitor::visit_Sequence(node);
    }

    void visit_AssignmentDefine(ir::AssignmentDefine* node) override {
      if (range_contains_cursor_(node->local()->range())) {
        result_ = node->local();
        return;
      }
      ir::TraversingVisitor::visit_AssignmentDefine(node);
    }

    ir::Node* result() const { return result_; }

   private:
    std::function<bool(Source::Range)> range_contains_cursor_;
    ir::Node* result_ = null;
  };

  DefinitionFinder finder(range_contains_cursor);
  auto check_method = [&](ir::Method* method) -> ir::Node* {
    if (method == null) return null;
    method->accept(&finder);
    return finder.result();
  };

  for (auto* method : program->methods()) {
    if (auto* res = check_method(method)) return res;
  }
  for (auto* klass : program->classes()) {
    for (auto* method : klass->methods()) {
      if (auto* res = check_method(method)) return res;
    }
    for (auto* constructor : klass->unnamed_constructors()) {
      if (auto* res = check_method(constructor)) return res;
    }
    for (auto* factory : klass->factories()) {
      if (auto* res = check_method(factory)) return res;
    }
    // Also check named constructors/statics in the statics scope.
    if (klass->statics() != null) {
      for (auto* node : klass->statics()->nodes()) {
        if (node->is_Method()) {
          if (auto* res = check_method(node->as_Method())) return res;
        }
      }
    }
  }
  for (auto* global : program->globals()) {
    if (auto* res = check_method(global)) return res;
  }

  return null;
}

void FindReferencesPipeline::post_resolve(Resolver* resolver, ir::Program* program) {
  if (lsp() == null || !lsp()->has_selection_handler()) return;
  auto* handler = static_cast<FindReferencesHandler*>(lsp()->selection_handler());
  auto* target = handler->target();

  // Capture show/export reference data from the resolver before it goes
  // out of scope. This is needed for renaming symbols that appear in
  // show/export clauses of import statements.
  show_export_references_ = resolver->show_export_references();

  // Fall back to scanning definitions if the cursor was on a definition site.
  if (target == null) {
    target = find_definition_at_cursor(
        program, source_manager(), lsp_selection_path_, line_number_, column_number_);
  }

  // Check if the cursor is on the name part of a named constructor/factory.
  // For `constructor.bar`, the IR range only covers "constructor", so
  // find_definition_at_cursor won't match when the cursor is on "bar".
  if (target == null) {
    auto& ir_to_ast = resolver->ir_to_ast_map();
    auto range_contains_cursor = [&](Source::Range range) -> bool {
      if (!range.is_valid()) return false;
      auto from = source_manager()->compute_location(range.from());
      if (!from.is_valid()) return false;
      if (strcmp(from.source->absolute_path(), lsp_selection_path_) != 0) return false;
      if (from.line_number != line_number_) return false;
      auto to = source_manager()->compute_location(range.to());
      int cursor_col_0 = column_number_ - 1;
      return cursor_col_0 >= from.offset_in_line && cursor_col_0 < to.offset_in_line;
    };
    for (auto* klass : program->classes()) {
      if (klass->statics() == null) continue;
      for (auto* node : klass->statics()->nodes()) {
        if (!node->is_Method()) continue;
        auto* method = node->as_Method();
        if (!method->is_constructor() && !method->is_factory()) continue;
        auto probe = ir_to_ast.find(method);
        if (probe == ir_to_ast.end()) continue;
        if (!probe->second->is_Method()) continue;
        auto* ast_method = probe->second->as_Method();
        if (ast_method->name_or_dot()->is_Dot()) {
          auto name_range = ast_method->name_or_dot()->as_Dot()->name()->selection_range();
          if (range_contains_cursor(name_range)) {
            target = method;
            break;
          }
        }
      }
      if (target != null) break;
    }
  }

  if (target != null) {
    auto& ir_to_ast = resolver->ir_to_ast_map();
    emit_all_references(target, program, ir_to_ast);
    // Not reached — emit_all_references calls exit(0).
  }

  // Target not found during resolution. The cursor may be on a virtual call
  // site whose target is only resolved during type checking (call_virtual
  // callback). Save state and return to let type checking proceed.
  program_ = program;
  ir_to_ast_map_ = std::move(resolver->ir_to_ast_map());
}

void FindReferencesPipeline::post_type_check() {
  if (lsp() == null || !lsp()->has_selection_handler()) { exit(0); return; }
  auto* handler = static_cast<FindReferencesHandler*>(lsp()->selection_handler());
  auto* target = handler->target();

  if (target != null && program_ != null) {
    emit_all_references(target, program_, ir_to_ast_map_);
    // Not reached.
  }
  exit(0);
}

void FindReferencesPipeline::emit_all_references(ir::Node* target,
                                                  ir::Program* program,
                                                  UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast) {
  // When the target is a FieldStub (synthetic getter/setter), redirect to the
  // underlying Field. The user intends to rename the field, which requires
  // renaming all getter calls, setter calls, the field definition, and any
  // field-storing parameters.
  if (target->is_FieldStub()) {
    target = target->as_FieldStub()->field();
  }

  // Refuse to rename SDK symbols — their source files are not user-editable.
  if (is_sdk_target(target, source_manager())) exit(0);

  // Determine the target's name and its length for range trimming.
  const char* name = target_name(target);
  int name_len = (name != null) ? static_cast<int>(strlen(name)) : 0;

  // When the target is a field, bridge to the getter and setter FieldStubs
  // for virtual call matching. Field access like `obj.my-field` compiles to
  // a CallVirtual dispatching to the getter/setter, so VirtualCallFilter
  // must target these stubs.
  ir::FieldStub* field_getter = null;
  ir::FieldStub* field_setter = null;
  if (target->is_Field()) {
    auto* field = target->as_Field();
    if (field->holder() != null) {
      for (auto* method : field->holder()->methods()) {
        if (method->is_FieldStub()) {
          auto* stub = method->as_FieldStub();
          if (stub->field() == field) {
            if (stub->is_getter()) field_getter = stub;
            else field_setter = stub;
          }
        }
      }
    }
  }

  // Build the virtual call filter. For fields, use the getter FieldStub
  // so that `obj.field` call sites are matched.
  auto filter_target = field_getter != null
      ? static_cast<ir::Node*>(field_getter) : target;
  auto virtual_call_filter = VirtualCallFilter::build(
      filter_target, program, source_manager());

  // For field targets, also register the setter so that assignment sites
  // (e.g., `obj.field = value`) are matched by the filter.
  if (field_setter != null) {
    virtual_call_filter.set_setter(field_setter);
  }

  // Create the visitor for expression-level reference finding.
  // The definition range is passed so the visitor can skip compiler-generated
  // references that coincide with the definition site.
  Source::Range definition_range = target_range(target);

  // For named constructors and factories, ir::Method::range() covers only the
  // "constructor" keyword (set from ast::Method::selection_range() during
  // resolution — see parser.cc:820 and resolver.cc:1792). The actual name
  // (e.g., "my-named-ctor" in "constructor.my-named-ctor") lives in the
  // ast::Dot node's name() Identifier.  Use its range instead.
  if (target->is_Method()) {
    auto* method = target->as_Method();
    if ((method->is_constructor() || method->is_factory()) &&
        method->holder() != null) {
      auto* ast_node = ir_to_ast.lookup(target);
      if (ast_node != null && ast_node->is_Method()) {
        auto* name_or_dot = ast_node->as_Method()->name_or_dot();
        if (name_or_dot != null && name_or_dot->is_Dot()) {
          definition_range = name_or_dot->as_Dot()->name()->selection_range();
        }
      }
    }
  }

  FindReferencesVisitor visitor(
      target, definition_range, name_len, source_manager(), ir_to_ast,
      lsp()->protocol(), virtual_call_filter);

  // Emit the definition's own location.
  if (definition_range.is_valid()) {
    auto from = source_manager()->compute_location(definition_range.from());
    auto to = source_manager()->compute_location(definition_range.to());

    int start_col = utf16_offset_in_line(from);
    int end_col = utf16_offset_in_line(to);

    // Trim prefix syntax from the definition range, same as for reference
    // ranges — e.g., "[block-param]" → "block-param".
    if (name_len > 0 &&
        from.line_number == to.line_number &&
        (end_col - start_col) > name_len) {
      start_col = end_col - name_len;
    }

    lsp()->protocol()->find_references()->emit(
        from.source->absolute_path(),
        from.line_number - 1, start_col,
        to.line_number - 1, end_col);
  }

  // --- Override/implementation definitions ---
  // When renaming a virtual method (or field), all definitions sharing the
  // same name and shape in the participating class hierarchy must be renamed
  // together to avoid breaking the program.
  if (virtual_call_filter.is_active()) {
    auto* filter_method = virtual_call_filter.method();
    auto filter_shape = filter_method->resolution_shape().to_plain_shape()
                            .to_equivalent_call_shape();
    for (auto* klass : virtual_call_filter.participating_classes().underlying_set()) {
      for (auto* method : klass->methods()) {
        if (method == target || method == field_getter || method == field_setter) continue;
        bool shape_matches = method->resolution_shape().accepts(filter_shape);
        if (!shape_matches && field_setter != null) {
          auto setter_shape = field_setter->resolution_shape().to_plain_shape()
                                  .to_equivalent_call_shape();
          shape_matches = method->resolution_shape().accepts(setter_shape);
        }
        if (method->name() == filter_method->name() && shape_matches) {
          // For FieldStub overrides, emit the field's own range (the field
          // definition name), not the synthetic getter/setter range.
          if (method->is_FieldStub()) {
            visitor.emit_range(method->as_FieldStub()->field()->range());
          } else {
            visitor.emit_range(method->range());
          }
        }
      }
    }
  }

  // --- Class-specific reference scanning ---
  // When renaming a class, we must find all places the class name appears:
  // extends/implements/with clauses, type annotations on parameters/return
  // types/fields, constructor calls (handled by the visitor), and is/as
  // checks (handled by the visitor).
  if (target->is_Class()) {
    auto* target_class = target->as_Class();

    // Hierarchy references: extends, implements, with clauses.
    for (auto* klass : program->classes()) {
      auto* ast_node = ir_to_ast.lookup(klass);
      if (ast_node == null || !ast_node->is_Class()) continue;
      auto* ast_class = ast_node->as_Class();

      if (klass->has_super() && klass->super() == target_class) {
        if (ast_class->super() != null) {
          visitor.emit_range(ast_class->super()->selection_range());
        }
      }

      auto ir_interfaces = klass->interfaces();
      auto ast_interfaces = ast_class->interfaces();
      for (int i = 0; i < ir_interfaces.length() && i < ast_interfaces.length(); i++) {
        if (ir_interfaces[i] == target_class) {
          visitor.emit_range(ast_interfaces[i]->selection_range());
        }
      }

      auto ir_mixins = klass->mixins();
      auto ast_mixins = ast_class->mixins();
      for (int i = 0; i < ir_mixins.length() && i < ast_mixins.length(); i++) {
        if (ir_mixins[i] == target_class) {
          visitor.emit_range(ast_mixins[i]->selection_range());
        }
      }
    }

    // Type annotations: scan parameter types, return types, and field types
    // across every method and class in the program.
    auto scan_method_types = [&](ir::Method* method) {
      for (auto* param : method->parameters()) {
        if (param->type().is_class() && param->type().klass() == target_class) {
          auto* ast_param = ir_to_ast.lookup(param);
          if (ast_param != null && ast_param->is_Parameter()) {
            auto* ast_type = ast_param->as_Parameter()->type();
            if (ast_type != null) visitor.emit_range(ast_type->selection_range());
          }
        }
      }
      if (method->return_type().is_class() &&
          method->return_type().klass() == target_class) {
        auto* ast_method = ir_to_ast.lookup(method);
        if (ast_method != null && ast_method->is_Method()) {
          auto* ast_ret = ast_method->as_Method()->return_type();
          if (ast_ret != null) visitor.emit_range(ast_ret->selection_range());
        }
      }
    };

    for (auto* klass : program->classes()) {
      for (auto* method : klass->methods()) scan_method_types(method);
      for (auto* ctor : klass->unnamed_constructors()) scan_method_types(ctor);
      for (auto* factory : klass->factories()) scan_method_types(factory);
      // Statics (named constructors, static methods, static fields).
      if (klass->statics() != null) {
        for (auto* method : klass->statics()->nodes()) {
          scan_method_types(method);
        }
      }

      for (auto* field : klass->fields()) {
        if (field->type().is_class() && field->type().klass() == target_class) {
          auto* ast_field = ir_to_ast.lookup(field);
          if (ast_field != null && ast_field->is_Field()) {
            auto* ast_type = ast_field->as_Field()->type();
            if (ast_type != null) visitor.emit_range(ast_type->selection_range());
          }
        }
      }
    }
    // Global functions and global variables.
    for (auto* method : program->methods()) scan_method_types(method);
    for (auto* global : program->globals()) scan_method_types(global);
  }

  // --- Field-specific reference scanning ---
  if (target->is_Field()) {
    auto* target_field = target->as_Field();
    if (target_field->holder() != null) {
      // Find field-storing parameters in constructors and factories.
      // A field-storing parameter (e.g., `--my-field`) shares its name with
      // the field and must be renamed when the field is renamed.
      auto check_method_for_field_storing = [&](ir::Method* method) {
        for (auto* param : method->parameters()) {
          if (param->name() == target_field->name()) {
            auto* ast_param = ir_to_ast.lookup(param);
            if (ast_param != null && ast_param->is_Parameter() &&
                ast_param->as_Parameter()->is_field_storing()) {
              visitor.emit_range(ast_param->selection_range());
            }
          }
        }
      };
      for (auto* ctor : target_field->holder()->unnamed_constructors()) {
        check_method_for_field_storing(ctor);
      }
      for (auto* factory : target_field->holder()->factories()) {
        check_method_for_field_storing(factory);
      }
      // Named constructors are in statics.
      if (target_field->holder()->statics() != null) {
        for (auto* method : target_field->holder()->statics()->nodes()) {
          if (method->is_constructor() || method->is_factory()) {
            check_method_for_field_storing(method);
          }
        }
      }
    }
  }

  // --- Show/export clause references ---
  // When a symbol appears in an import's `show` clause or an `export`
  // directive, the clause text must be updated when the symbol is renamed.
  for (const auto& ref : show_export_references_) {
    if (unwrap_reference(ref.target) == target) {
      visitor.emit_range(ref.range);
    }
  }

  // --- Toitdoc reference scanning ---
  // When a toitdoc comment references the target via `$symbol`, that
  // reference must be updated when the target is renamed.
  toitdocs()->for_each([&](void* key, Toitdoc<ir::Node*> ir_toitdoc) {
    if (!ir_toitdoc.is_valid()) return;
    auto ir_refs = ir_toitdoc.refs();

    // Check if any ref in this toitdoc points to the target.
    bool has_matching_ref = false;
    for (int i = 0; i < ir_refs.length(); i++) {
      auto* ref_target = ir_refs[i];
      if (ref_target == null) continue;
      // FieldStub → Field redirect (matching the FieldStub unwrapping above).
      if (ref_target->is_FieldStub()) ref_target = ref_target->as_FieldStub()->field();
      if (ref_target == target) {
        has_matching_ref = true;
        break;
      }
    }
    if (!has_matching_ref) return;

    // Look up the AST node to get source ranges for the toitdoc refs.
    auto* ir_node = static_cast<ir::Node*>(key);
    auto probe = ir_to_ast.find(ir_node);
    if (probe == ir_to_ast.end()) return;
    auto* ast_node = probe->second;

    // Get the AST toitdoc from the declaration.
    Toitdoc<ast::Node*> ast_toitdoc = Toitdoc<ast::Node*>::invalid();
    if (ast_node->is_Class()) {
      ast_toitdoc = ast_node->as_Class()->toitdoc();
    } else if (ast_node->is_Method()) {
      ast_toitdoc = ast_node->as_Method()->toitdoc();
    } else if (ast_node->is_Field()) {
      ast_toitdoc = ast_node->as_Field()->toitdoc();
    }
    if (!ast_toitdoc.is_valid()) return;

    auto ast_refs = ast_toitdoc.refs();
    ASSERT(ast_refs.length() == ir_refs.length());

    for (int i = 0; i < ir_refs.length(); i++) {
      auto* ref_target = ir_refs[i];
      if (ref_target == null) continue;
      if (ref_target->is_FieldStub()) ref_target = ref_target->as_FieldStub()->field();
      if (ref_target != target) continue;

      auto* ast_ref_node = ast_refs[i];
      if (!ast_ref_node->is_ToitdocReference()) continue;
      auto* toitdoc_ref = ast_ref_node->as_ToitdocReference();

      auto* ref_target_expr = toitdoc_ref->target();
      if (ref_target_expr == null) continue;

      // For Dot expressions (e.g., `$Class.method`), emit only the part
      // that corresponds to the rename target.
      if (ref_target_expr->is_Dot()) {
        auto* dot = ref_target_expr->as_Dot();
        // The resolver resolves `$Class.method` to the method, not the class.
        // So a matching ref means we're renaming the method → emit the name part.
        visitor.emit_range(dot->name()->selection_range());
      } else {
        visitor.emit_range(ref_target_expr->selection_range());
      }
    }
  });

  // --- Expression-level references ---
  // The visitor traverses all IR expression trees to find:
  // - Static references (ReferenceMethod, ReferenceLocal, ReferenceGlobal)
  // - Constructor calls for class targets (ReferenceMethod → holder class)
  // - Virtual call sites (CallVirtual matching VirtualCallFilter)
  // - IS/AS/local type checks for class targets (Typecheck nodes)
  visitor.visit(program);
  exit(0);
}

void PrepareRenamePipeline::setup_lsp_selection_handler() {
  lsp()->setup_find_references_handler(source_manager());
}

void PrepareRenamePipeline::post_resolve(Resolver* resolver, ir::Program* program) {
  if (lsp() == null || !lsp()->has_selection_handler()) return;
  auto* handler = static_cast<FindReferencesHandler*>(lsp()->selection_handler());
  auto* target = handler->target();

  // Fall back to scanning definitions if the cursor was on a definition site.
  if (target == null) {
    target = find_definition_at_cursor(
        program, source_manager(), lsp_selection_path_, line_number_, column_number_);
  }

  if (target != null) {
    // Use the cursor-site range (from the handler callback) so that the
    // prepareRename response points to the identifier at the cursor, not at
    // the definition.  Falls back to the target's own range when the cursor
    // is directly on the definition (cursor_range is invalid).
    emit_prepare_rename(target, handler->cursor_range());
    // Never reached — emit_prepare_rename calls exit(0).
  }

  // Check if the cursor is on the name part of a named constructor/factory.
  // For `constructor.bar`, the IR range only covers "constructor", so
  // find_definition_at_cursor won't match when the cursor is on "bar".
  // We use the resolver's ir_to_ast map to check the AST name range.
  auto& ir_to_ast = resolver->ir_to_ast_map();
  auto range_contains_cursor = [&](Source::Range range) -> bool {
    if (!range.is_valid()) return false;
    auto from = source_manager()->compute_location(range.from());
    if (!from.is_valid()) return false;
    if (strcmp(from.source->absolute_path(), lsp_selection_path_) != 0) return false;
    if (from.line_number != line_number_) return false;
    auto to = source_manager()->compute_location(range.to());
    int cursor_col_0 = column_number_ - 1;
    return cursor_col_0 >= from.offset_in_line && cursor_col_0 < to.offset_in_line;
  };
  for (auto* klass : program->classes()) {
    if (klass->statics() == null) continue;
    for (auto* node : klass->statics()->nodes()) {
      if (!node->is_Method()) continue;
      auto* method = node->as_Method();
      if (!method->is_constructor() && !method->is_factory()) continue;
      auto probe = ir_to_ast.find(method);
      if (probe == ir_to_ast.end()) continue;
      auto* ast_method = probe->second->as_Method();
      if (ast_method->name_or_dot()->is_Dot()) {
        auto name_range = ast_method->name_or_dot()->as_Dot()->name()->selection_range();
        if (range_contains_cursor(name_range)) {
          emit_prepare_rename(method, name_range);
          // Never reached.
        }
      }
    }
  }

  // If still not found, the cursor may be on a virtual call site.
  // Virtual calls are resolved during type-checking, so we return here
  // to let the pipeline continue to the type-checker. The post_type_check
  // method handles the result after type-checking.
}

void PrepareRenamePipeline::post_type_check() {
  if (lsp() == null || !lsp()->has_selection_handler()) { exit(0); return; }
  auto* handler = static_cast<FindReferencesHandler*>(lsp()->selection_handler());
  auto* target = handler->target();

  if (target != null) {
    emit_prepare_rename(target, handler->cursor_range());
  }
  exit(0);
}

void PrepareRenamePipeline::emit_prepare_rename(ir::Node* target,
                                                 Source::Range range_override) {
  const char* name = target_name(target);
  Source::Range range = range_override.is_valid() ? range_override : target_range(target);

  if (name == null || !range.is_valid()) exit(0);

  // Refuse to rename SDK symbols — their source files are not user-editable.
  if (is_sdk_target(target, source_manager())) exit(0);

  auto from = source_manager()->compute_location(range.from());
  auto to = source_manager()->compute_location(range.to());

  int start_col = utf16_offset_in_line(from);
  int end_col = utf16_offset_in_line(to);

  // The source range may include prefix syntax that is not part of the
  // renamable identifier — e.g., "--" for named parameters, "[" for block
  // parameters, or "." for dot-access.  Adjust the start column so the
  // emitted range covers exactly the name.
  int name_len = static_cast<int>(strlen(name));
  if (from.line_number == to.line_number && (end_col - start_col) > name_len) {
    start_col = end_col - name_len;
  }

  lsp()->protocol()->prepare_rename()->emit(
      from.source->absolute_path(),
      from.line_number - 1, start_col,
      to.line_number - 1, end_col,
      name);
  exit(0);
}

/// Returns the error-unit if the file can't be parsed.
///
/// If `path == ""` assumes that an error has already been reported, and just
///   returns the error unit.
ast::Unit* Pipeline::_parse_source(Source* source) {
  if (Flags::trace) printf("Parsing file '%s'\n", source->absolute_path());
  return parse(source);
}

static const uint8* wrap_direct_script_expression(const char* direct_script, Diagnostics* diagnostics) {
  if (Flags::trace) printf("Parsing provided script\n");
  std::string header =
    "main:\n"
    "  print __entry__expression\n"
    "__entry__expression:\n"
    "  return "; // Expression will be added here.
  if (strchr(direct_script, '\n') != null) {
    diagnostics->report_error("Command line expression does not support newline");
    exit(1);
  }
  const uint8* text = unsigned_cast(strdup((header + direct_script).c_str()));
  return text;
}

namespace {
enum class AddSegmentResult {
  OK,
  NOT_A_DIRECTORY,
  NOT_A_REGULAR_FILE,
  NOT_FOUND,
};
}  // Anonymous namespace.

/// Adds the given segment to the path_builder.
/// Modifies the builder.
/// If 'should_check_is_toit_file' is true, also adds the '.toit' extension.
/// If 'should_check_is_toit_file' is true, checks that the result is a regular file.
/// If 'should_check_is_toit_file' is false, checks that the result is a directory.
static AddSegmentResult add_segment(PathBuilder* path_builder,
                                    const char* segment,
                                    Filesystem* fs,
                                    bool should_check_is_toit_file,
                                    const Source::Range& error_range,
                                    Diagnostics* diagnostics) {
  char* dir_path = path_builder->strdup();
  Defer free_dir_path { [&] { free(dir_path); } };

  // Checks that the casing of the found path is actually correct.
  // Assumes that the file was found.
  // On Linux this is usually not an issue, but it might happen with mounted filesystems that are
  // not case-sensitive.
  auto check_casing = [&](const char* path) {
    // With the LSP, the 'list_toit_directory_entries' might not provide the file we found.
    // Keep track of whether we found a case-sensitive, and case-insensitive match.
    bool found_sensitive_match = false;  // Whether we found a case-sensitive match.
    const char* insensitive_match = null;  // The case-insensitive match, if we found one.
    fs->list_toit_directory_entries(dir_path, [&] (const char* entry, bool is_dir) {
      bool entry_match_is_cs = true;
      for (int i = 0;; i++) {
        if (entry[i] == '\0' && segment[i] == '\0') {
          // Full match.
          if (entry_match_is_cs) {
            found_sensitive_match = true;
            return false;  // No need to continue.
          } else {
            insensitive_match = strdup(entry);
            return true;
          }
        }
        if (entry[i] == '_' && segment[i] == '-') {
          // Assume they match. This might not always be correct, but we are just
          // trying to provide good warnings.
          continue;
        }
        if (entry[i] != segment[i]) {
          if (tolower(entry[i]) == tolower(segment[i])) {
            if (insensitive_match != null) {
              // No need to continue with this entry. We already found a case-insensitive match.
              return true;
            }
            entry_match_is_cs = false;
          } else {
            return true;  // Try the next entry.
          }
        }
      }
    });
    if (!found_sensitive_match && insensitive_match != null) {
      diagnostics->report_warning(error_range,
                                  "Import segment '%s' does not match case of segment '%s' in the filename",
                                  segment,
                                  insensitive_match);
    }
    free(const_cast<char*>(insensitive_match));
  };

  auto check_path = [&]() {
    if (should_check_is_toit_file) {
      path_builder->add(".toit");
    }
    std::string path = path_builder->buffer();
    auto path_c_str = path.c_str();
    if (should_check_is_toit_file) {
      if (fs->is_regular_file(path_c_str)) {
        check_casing(path_c_str);
        return AddSegmentResult::OK;
      }
      if (fs->exists(path_c_str)) {
        return AddSegmentResult::NOT_A_REGULAR_FILE;
      }
    } else {
      if (fs->is_directory(path_c_str)) {
        check_casing(path_c_str);
        return AddSegmentResult::OK;
      }
      if (fs->exists(path_c_str)) {
        return AddSegmentResult::NOT_A_DIRECTORY;
      }
    }
    return AddSegmentResult::NOT_FOUND;
  };

  // We need to handle cases where the segment contains '-' or '_'.
  // So remember the length of the path before we add the segment.
  int path_length_before_segment = path_builder->length();

  // First add the segment verbatim. In most cases that will just work.
  path_builder->join(segment);
  auto result = check_path();
  if (result != AddSegmentResult::NOT_FOUND) return result;

  const char* old_style = IdentifierValidator::deprecated_underscore_identifier(segment, strlen(segment));
  if (old_style == segment) {
    // Didn't contain any '-'.
    return AddSegmentResult::NOT_FOUND;
  }
  path_builder->reset_to(path_length_before_segment);
  path_builder->join(old_style);
  return check_path();
}

// Provides a better error message for failed imports.
static void _report_failed_import(ast::Import* import,
                                  const Package import_package,
                                  ast::Node* note_node,
                                  AddSegmentResult error_result,
                                  const char* failed_path,
                                  const char* alternative_path,
                                  bool found_alternative_directory,
                                  Filesystem* fs,
                                  Diagnostics* diagnostics) {
  auto segments = import->segments();
  // Build the error-segments. We are rebuilding the original import line.
  // Simply join all segments with "." and make sure the leading
  // dots are correct.
  std::string error_segments;
  if (import->is_relative()) {
    error_segments += '.';
    for (int i = 0; i < import->dot_outs(); i++) error_segments += '.';
  }
  for (int i = 0; i < segments.length(); i++) {
    if (i != 0) error_segments += '.';
    error_segments += segments[i]->data().c_str();
  }

  auto build_error_path = [&](const char* path) {
    return import_package.build_error_path(fs, path);
  };

  diagnostics->start_group();
  diagnostics->report_error(import, "Failed to import '%s'", error_segments.c_str());
  if (found_alternative_directory) {
    // We tried `foo.toit` and `foo/foo.toit`, and found `foo` but `foo/foo.toit`
    // was not found.
    // This is common enough that we can provide a better error message.
    auto note_path = build_error_path(alternative_path);
    if (error_result == AddSegmentResult::NOT_FOUND) {
      diagnostics->report_note(note_node,
                                "Folder '%s' exists, but is missing a '%s.toit' file",
                                note_path.c_str(),
                                segments.last()->data().c_str());
    } else {
      ASSERT(error_result == AddSegmentResult::NOT_A_REGULAR_FILE);
      diagnostics->report_note(note_node,
                                "Cannot read '%s.toit': not a regular file",
                                note_path.c_str(),
                                segments.last()->data().c_str());
    }
  } else if (failed_path != null && alternative_path != null) {
    // We tried `foo.toit` and `foo/foo.toit`, and found neither.
    auto note_path1 = build_error_path(failed_path);
    auto note_path2 = build_error_path(alternative_path);
    diagnostics->report_note(note_node,
                             "Missing library file. Tried '%s' and '%s%c%s.toit'",
                             note_path1.c_str(),
                             note_path2.c_str(),
                             fs->path_separator(),
                             segments.last()->data().c_str());
  } else if (alternative_path != null) {
    // Special case where we only tried `foo/foo.toit`. In fact, we tried
    // `src/foo.toit` as the first segment was used for the package name.
    auto note_path = build_error_path(alternative_path);
    diagnostics->report_note(note_node,
                             "Missing library file. Tried '%s'",
                             note_path.c_str());
  } else {
    auto note_path = build_error_path(failed_path);
    switch (error_result) {
      case AddSegmentResult::NOT_A_REGULAR_FILE:
        diagnostics->report_note(note_node, "Cannot read '%s': not a regular file", note_path.c_str());
        break;
      case AddSegmentResult::NOT_A_DIRECTORY:
        diagnostics->report_note(note_node, "Cannot enter '%s': not a folder", note_path.c_str());
        break;
      case AddSegmentResult::NOT_FOUND:
        diagnostics->report_note(note_node, "Cannot enter '%s': folder does not exist", note_path.c_str());
        break;
      default:
        UNREACHABLE();
    }
  }
  diagnostics->end_group();
}

/// Extracts the path for the [import] that is contained in [unit].
/// Returns null if the import couldn't be found or if there was an error.
/// Returns the corresponding source, otherwise.
Source* Pipeline::_load_import(ast::Unit* unit,
                               ast::Import* import,
                               const PackageLock& package_lock) {
  if (unit->source() == null) FATAL("unit without source");

  if (SourceManager::is_virtual_file(unit->absolute_path()) && import->is_relative()) {
    diagnostics()->report_error(import, "Relative import not possible from virtual file");
    // Virtual files don't have a location in the file system and thus can't have
    // relative imports.
    return null;
  }

  bool is_relative = import->is_relative();

  auto segments = import->segments();
  if (segments.is_empty()) {
    ASSERT(diagnostics()->encountered_error());
    return null;
  }

  auto unit_package = package_lock.package_for(unit->absolute_path(), filesystem());
  ASSERT(unit_package.is_ok());
  std::string unit_package_id = unit_package.id();

  const char* lsp_path = null;
  const char* lsp_segment = null;
  bool lsp_is_first_segment = false;

  std::string expected_import_package_id;
  PathBuilder import_path_builder(filesystem());
  int relative_segment_start = 0;
  bool dotted_out = false;
  Package import_package;

  Source* result = null;
  auto result_package = Package::invalid();

  if (is_relative) {
    // The file is relative to the unit_package.
    import_package = unit_package;
    // Relative paths must stay in the same package.
    expected_import_package_id = unit_package_id;
    import_path_builder.join(unit->absolute_path());
    import_path_builder.join("..");  // Drops the filename.
    for (int i = 0; i < import->dot_outs(); i++) {
      import_path_builder.join("..");
    }
    import_path_builder.canonicalize();
    if (import->dot_outs() > 0) {
      // We check if a file in this folder would still be part of this package.
      PathBuilder fake_path_builder = import_path_builder;
      fake_path_builder.join("fake.toit");
      auto dotted_package = package_lock.package_for(fake_path_builder.buffer(), filesystem());
      if (!dotted_package.is_ok() || dotted_package.id() != expected_import_package_id) {
        dotted_out = true;
        // Note that we don't even allow this if the user comes back into the package.
        // For example, say we are in package `bar` with a path ending in "bar".
        // Then `import ..bar` would get back to the same package. However, that's very
        // brittle and packages shouldn't know where they are located.
        diagnostics()->report_error(import, "Import is dotting out of its own package: '%s'", import_path_builder.c_str());
      }
    }
  } else {
    auto module_segment = segments[0];
    auto prefix = std::string(module_segment->data().c_str());
    if (module_segment->is_LspSelection()) {
      lsp_path = "",
      lsp_segment = module_segment->data().c_str();
      lsp_is_first_segment = true;
    }
    import_package = package_lock.resolve_prefix(unit_package, prefix);
    auto error_range = module_segment->selection_range();
    switch (import_package.error_state()) {
      case Package::STATE_OK:
        // All good.
        break;

      case Package::STATE_INVALID:
        if (package_lock.has_errors()) {
          diagnostics()->report_error(error_range,
                                      "Package for prefix '%s' not found, but lock file has errors",
                                      prefix.c_str());
        } else {
          diagnostics()->report_error(error_range,
                                      "Package for prefix '%s' not found",
                                      prefix.c_str());
        }
        goto done;

      case Package::STATE_ERROR:
        diagnostics()->report_error(error_range,
                                    "Package for prefix '%s' not found due to error in lock file",
                                    prefix.c_str());
        goto done;

      case Package::STATE_NOT_FOUND:
        diagnostics()->report_error(error_range,
                                    "Package '%s' for prefix '%s' not found",
                                    import_package.id().c_str(),
                                    prefix.c_str());
        goto done;
    }
    expected_import_package_id = import_package.id();
    import_path_builder.join(import_package.absolute_path());
    relative_segment_start = import_package.is_sdk_prefix() ? 0 : 1;
    ASSERT(import_path_builder[import_path_builder.length() - 1] != '/');
  }

  if (relative_segment_start == segments.length()) {
    // Something like `import foo` where `foo` is the name of a package.
    // We only allow `foo.toit` (inside the package's `src` directory), but
    // not `foo/foo.toit`.
    // If we know the name of the package, then use that to find the library. Otherwise,
    // use the last segment of the import. The latter is deprecated.
    int length_before_segment = import_path_builder.length();
    auto name = import_package.name();
    const char* next_segment;
    if (name == Package::NO_NAME) {
      next_segment = segments[segments.length() - 1]->data().c_str();
    } else {
      next_segment = IdentifierValidator::canonicalize(name.c_str(), name.size());
    }
    auto result = add_segment(&import_path_builder,
                              next_segment,
                              filesystem(),
                              true,  // Must be a toit file.
                              segments[segments.length() - 1]->selection_range(),
                              diagnostics());
    if (result != AddSegmentResult::OK) {
      // To make it easier to share the error reporting with the code below
      // we have to remove the segment again.
      import_path_builder.reset_to(length_before_segment);
      _report_failed_import(import,
                            import_package,
                            segments[segments.length() - 1],
                            result,
                            null,  // No default path.
                            import_path_builder.c_str(),  // We only tried the alternative path.
                            true, // Did find the alternative directory, since we found a package and its 'src' directory.
                            filesystem(),
                            diagnostics());
      goto done;
    }
  }
  for (int i = relative_segment_start; i < segments.length(); i++) {
    auto segment_id = segments[i];
    auto segment = segment_id->data();
    if (segment_id->is_LspSelection()) {
      lsp_path = import_path_builder.strdup();
      lsp_segment = segment.c_str();
    }
    bool is_last_segment = i == segments.length() - 1;
    int length_before_new_segment = import_path_builder.length();
    auto result = add_segment(&import_path_builder,
                              segment.c_str(),
                              filesystem(),
                              is_last_segment, // Check whether it's a toit file for the last segment.
                              segment_id->selection_range(),
                              diagnostics());
    if (result != AddSegmentResult::OK) {
      if (!is_last_segment || result != AddSegmentResult::NOT_FOUND) {
        _report_failed_import(import,
                              import_package,
                              segment_id,
                              result,
                              import_path_builder.c_str(),
                              null,  // No alternative path.
                              false, // Didn't find the alternative directory.
                              filesystem(),
                              diagnostics());
        // Don't return just yet, but give the lsp handler an opportunity to run.
        goto done;
      } else {
        // We didn't find the toit file.
        // Keep the toit file path for error reporting.
        const char* error_path = import_path_builder.strdup();

        // Give it another try, this time duplicating the last segment.
        // For example, for `import foo` we search for `foo.toit` and `foo/foo.toit`.
        import_path_builder.reset_to(length_before_new_segment);
        result = add_segment(&import_path_builder,
                             segment.c_str(),
                             filesystem(),
                             false,  // Now it must be a directory.
                             segment_id->selection_range(),
                             diagnostics());
        bool found_alternative_directory = result == AddSegmentResult::OK;
        int length_after_folder = import_path_builder.length();

        if (result == AddSegmentResult::OK) {

          // We found a directory, so we duplicate the last segment.
          result = add_segment(&import_path_builder,
                               segment.c_str(),
                               filesystem(),
                               true,  // Now it must be a toit file.
                               segment_id->selection_range(),
                               diagnostics());
        }
        if (result != AddSegmentResult::OK) {
          import_path_builder.reset_to(length_after_folder);
          _report_failed_import(import,
                                import_package,
                                segment_id,
                                result,
                                error_path,
                                import_path_builder.c_str(),
                                found_alternative_directory,
                                filesystem(),
                                diagnostics());
          // Don't return just yet, but give the lsp handler an opportunity to run.
          goto done;
        }
      }
    }
  }
  {
    std::string import_path = import_path_builder.buffer();
    result_package = package_lock.package_for(import_path, filesystem());
    auto load_result = source_manager()->load_file(import_path, result_package);
    if (load_result.status == SourceManager::LoadResult::OK) {
      result = load_result.source;
    } else {
      load_result.report_error(import->selection_range(), diagnostics());
      // Don't return just yet, but give the lsp handler an opportunity to run.
      goto done;
    }
  }

  done:


  if (lsp_path != null) {
    lsp()->selection_handler()->import_path(lsp_path,
                                            lsp_segment,
                                            lsp_is_first_segment,
                                            result == null ? null : result->absolute_path(),
                                            unit_package,
                                            package_lock,
                                            filesystem());
  }

  if (result == null) {
    return null;
  }

  ASSERT(result_package.is_ok());
  if (result_package.id() != expected_import_package_id) {
    if (!dotted_out) {  // If we dotted out, then we already reported an error.
      // We ended up in a nested package.
      // In theory we could allow this, but it feels brittle.
      diagnostics()->report_error(import, "Import traverses package boundary: '%s'", import_path_builder.c_str());
    }
  }

  return result;
}

Source* Pipeline::_load_file(const char* path, const PackageLock& package_lock) {
  PathBuilder builder(filesystem());
  if (filesystem()->is_absolute(path)) {
    builder.join(path);
  } else {
    builder.join(filesystem()->relative_anchor(path));
    builder.join(path);
  }
  builder.canonicalize();
  auto package = package_lock.package_for(builder.buffer(), filesystem());
  auto load_result = source_manager()->load_file(builder.buffer(), package);
  if (load_result.status == SourceManager::LoadResult::OK) {
    return load_result.source;
  }

  load_result.report_error(diagnostics());
  exit(1);
}

std::vector<ast::Unit*> Pipeline::_parse_units(List<const char*> source_paths,
                                               const PackageLock& package_lock) {
  const char* sdk_lib_dir = source_manager()->library_root();

  std::vector<ast::Unit*> units;

  UnorderedMap<Source*, ast::Unit*> parsed_units;

  std::vector<std::string> canonicalized_source_paths;

  // Add the entry file first.
  // We are only allowed to add one source file here (even if there are
  //   multiple source_paths entries), so that the core library can
  //   be the second unit.
  // If there is more than one source_path, they are added after the core
  //   library.
  ASSERT(!source_paths.is_empty());
  auto entry_path = source_paths[0];
  auto entry_source = _load_file(entry_path, package_lock);
  auto entry_unit = _parse_source(entry_source);
  parsed_units[entry_source] = entry_unit;
  ASSERT(units.size() == ENTRY_UNIT_INDEX);
  units.push_back(entry_unit);

  // Add the core library which is implicitly imported.
  {
    PathBuilder builder(filesystem());
    builder.join(sdk_lib_dir);
    builder.join("core", "core.toit");
    auto source = _load_file(builder.c_str(), package_lock);
    // If the entry is the same as the core lib we will parse the core library
    // twice. That shouldn't be a problem.
    auto unit = _parse_source(source);
    parsed_units[unit->source()] = unit;
    ASSERT(units.size() == CORE_UNIT_INDEX);
    units.push_back(unit);
  }

  // All source paths except for the entry-path come after the core unit.
  for (int i = 1; i < source_paths.length(); i++) {
    auto path = source_paths[i];
    auto source = _load_file(path, package_lock);
    if (parsed_units.lookup(source) != null) {
      // The same filename was given multiple times.
      continue;
    }
    auto unit = _parse_source(source);
    parsed_units[source] = unit;
    units.push_back(unit);
  }

  // Transitively parse the source_files.
  // Note that we modify the vector inside the loop, growing it.
  for (size_t i = 0; i < units.size(); i++) {
    auto unit = units[i];
    auto imports = unit->imports();
    for (auto import : imports) {
      if (import->unit() != null) continue;
      auto import_source = _load_import(unit, import, package_lock);

      if (import_source == null) {
        ASSERT(diagnostics()->encountered_error());
        bool is_error_unit = true;
        auto error_unit = _new ast::Unit(is_error_unit);
        import->set_unit(error_unit);
        units.push_back(error_unit);
        continue;
      }

      auto parsed_unit = parsed_units.lookup(import_source);
      if (parsed_unit != null) {
        // Already parsed.
        import->set_unit(parsed_unit);
        continue;
      }

      auto import_unit = _parse_source(import_source);
      import->set_unit(import_unit);
      units.push_back(import_unit);
      parsed_units[import_source] = import_unit;
    }
  }

  return units;
}

static void assign_field_indexes(List<ir::Class*> classes) {
  ASSERT(_sorted_by_inheritance(classes));
  // We rely on the fact that the classes are sorted by inheritance.
  for (auto klass : classes) {
    int super_count = klass->has_super() ? klass->super()->total_field_count() : 0;
    klass->set_total_field_count(super_count + klass->fields().length());

    int index = super_count;
    for (auto field : klass->fields()) {
      field->set_resolved_index(index++);
    }
  }
}

static void assign_global_ids(List<ir::Global*> globals) {
  for (int i = 0; i < globals.length(); i++) {
    globals[i]->set_global_id(i);
  }
}

static bool check_sdk(const std::string& constraint, Diagnostics* diagnostics) {
  semver_t constraint_semver;
  ASSERT(constraint[0] == '^');
  int status = semver_parse(&constraint.c_str()[1], &constraint_semver);
  // We checked the version already during parsing of the lock file. So we know
  // the parsing must work.
  ASSERT(status == 0);

  semver_t compiler_semver;
  const char* compiler_version = vm_git_version();
  ASSERT(compiler_version[0] == 'v');
  status = semver_parse(&compiler_version[1], &compiler_semver);
  ASSERT(status == 0);

  if (semver_lt(compiler_semver, constraint_semver)) {
    diagnostics->report_error("The SDK constraint defined in the package.lock file is not satisfied: %s < %s",
                              compiler_version,
                              constraint.c_str());
    return false;
  };
  return true;
}

static void drop_abstract_methods(ir::Program* ir_program) {
  for (auto klass : ir_program->classes()) {
    switch (klass->kind()) {
      case ir::Class::Kind::CLASS:
      case ir::Class::Kind::MIXIN:
      case ir::Class::Kind::MONITOR:
        break;
      case ir::Class::Kind::INTERFACE:
        continue;
    }
    bool has_abstract_methods = false;
    for (auto method : klass->methods()) {
      if (method->is_abstract()) {
        has_abstract_methods = true;
        break;
      }
    }
    if (!has_abstract_methods) continue;
    ListBuilder<ir::MethodInstance*> remaining_methods;
    for (auto method : klass->methods()) {
      if (method->is_abstract()) continue;
      remaining_methods.add(method);
    }
    klass->replace_methods(remaining_methods.build());
  }
}

toit::Program* construct_program(ir::Program* ir_program,
                                 SourceMapper* source_mapper,
                                 TypeOracle* oracle,
                                 TypeDatabase* propagated_types,
                                 bool run_optimizations) {
  source_mapper->register_selectors(ir_program->classes());

  drop_abstract_methods(ir_program);
  add_lambda_boxes(ir_program);
  add_monitor_locks(ir_program);
  add_stub_methods_and_switch_to_plain_shapes(ir_program);
  add_interface_stub_methods(ir_program);

  apply_mixins(ir_program);

  ASSERT(_sorted_by_inheritance(ir_program->classes()));

  if (run_optimizations) optimize(ir_program, oracle);
  tree_shake(ir_program);

  // It is important that we seed and finalize the oracle in the same
  // state, so the IR nodes used to produce the somewhat unoptimized
  // program that we propagate types through can be matched up to the
  // corresponding IR nodes for the fully optimized version.
  if (propagated_types) {
    oracle->finalize(ir_program, propagated_types);
    optimize(ir_program, oracle);
    tree_shake(ir_program);
  } else {
    oracle->seed(ir_program);
  }

  // We assign the field ids very late in case we can inline field-accesses.
  assign_field_indexes(ir_program->classes());
  // Similarly, assign the global ids at the end, in case they can be tree
  // shaken or inlined.
  assign_global_ids(ir_program->globals());

  Backend backend(source_mapper->manager(), source_mapper);
  auto program = backend.emit(ir_program);
  return program;
}

// Sorts all classes.
// Changes the given 'classes' list so that:
// - top is the first class.
// - all other classes follow top in a depth-first order.
//   A super class is always directly preceded by its first sub (if there is any).
//   Any sibling of a sub follows after the first sub's children (and their children...).
// - After all classes, are all mixins.
// - Mixins are order in such a way that all dependencies are before their "subs". In
//   the case of mixins a dependency is either the super, or another mixin that is
//   referenced in a `with` clause. Here these are available as `m->mixins()`.
// - Finally, we have all interfaces.
//   These are, again, in depth-first order.
static void sort_classes(List<ir::Class*> classes) {
  ir::Class* top = null;
  ir::Class* top_mixin = null;
  ir::Class* top_interface = null;
  UnorderedMap<ir::Class*, std::vector<ir::Class*>> subs;

  for (auto klass : classes) {
    if (klass->super() != null) {
      subs[klass->super()].push_back(klass);
      if (klass->is_mixin() && !klass->mixins().is_empty()) {
        for (auto mixin : klass->mixins()) {
          subs[mixin].push_back(klass);
        }
      }
      continue;
    }
    switch (klass->kind()) {
      case ir::Class::Kind::CLASS:
      case ir::Class::Kind::MONITOR:
        top = klass;
        break;
      case ir::Class::Kind::MIXIN:
        top_mixin = klass;
        break;
      case ir::Class::Kind::INTERFACE:
        top_interface = klass;
        break;
    }
  }
  ASSERT(top != null);
  ASSERT(top_mixin != null);
  ASSERT(top_interface != null);

  Set<ir::Class*> done;

  auto are_all_mixin_parents_done = [&](ir::Class* klass) -> bool {
    if (!klass->is_mixin()) return true;
    if (klass->has_super() && !done.contains(klass->super())) return false;
    for (auto mixin : klass->mixins()) {
      if (!done.contains(mixin)) return false;
    }
    return true;
  };

  auto dfs_traverse = [&](ir::Class* klass) -> void {
    std::vector<ir::Class*> queue;
    queue.push_back(klass);
    while (!queue.empty()) {
      ir::Class* current = queue.back();
      queue.pop_back();
      if (done.contains(current)) {
        ASSERT(current->is_mixin());
        continue;
      }
      if (!are_all_mixin_parents_done(current)) {
        continue;
      }
      done.insert(current);
      auto probe = subs.find(current);
      if (probe != subs.end()) {
        queue.insert(queue.end(), probe->second.begin(), probe->second.end());
      }
    }
  };

  dfs_traverse(top);
  dfs_traverse(top_mixin);
  dfs_traverse(top_interface);

  ASSERT(done.size() == classes.length());
  int index = 0;
  for (auto klass : done) {
    classes[index++] = klass;
  }
}

Pipeline::Result Pipeline::run(List<const char*> source_paths, bool propagate) {
  // TODO(florian): this is hackish. We want to analyze asserts also in release mode,
  // but then remove the code when we generate code.
  // For now just enable asserts when we are analyzing.
  if (configuration_.is_for_analysis) {
    Flags::enable_asserts = true;
  }

#ifdef TOIT_OPTIMIZATION_OVERRIDE
  configuration_.optimization_level = TOIT_OPTIMIZATION_OVERRIDE;
#endif
#if defined(TOIT_ASSERT_OVERRIDE) && TOIT_ASSERT_OVERRIDE == 0
  Flags::enable_asserts = false;
#elif TOIT_ASSERT_OVERRIDE != 0
  Flags::enable_asserts = true;
#endif

  setup_lsp_selection_handler();

  auto fs = configuration_.filesystem;
  fs->initialize(diagnostics());
  source_paths = adjust_source_paths(source_paths);
  auto package_lock = load_package_lock(source_paths);

  if (package_lock.sdk_constraint() != "") {
    bool succeeded = check_sdk(package_lock.sdk_constraint(), diagnostics());
    if (!succeeded && !configuration_.force && configuration_.lsp == null) {
      diagnostics()->report_error("Compilation failed");
      exit(1);
    }
  }

  auto units = _parse_units(source_paths, package_lock);

  if (configuration_.dep_file != null) {
    ASSERT(configuration_.dep_format != Compiler::DepFormat::none);
    PlainDepWriter plain_writer;
    NinjaDepWriter ninja_writer;
    ListDepWriter list_writer;
    DepWriter* chosen_writer = null;
    switch (configuration_.dep_format) {
      case Compiler::DepFormat::plain:
        chosen_writer = &plain_writer;
        break;
      case Compiler::DepFormat::ninja:
        chosen_writer = &ninja_writer;
        break;
      case Compiler::DepFormat::list:
        chosen_writer = &list_writer;
        break;
      case Compiler::DepFormat::none:
        UNREACHABLE();
    }
    chosen_writer->write_deps_to_file_if_different(configuration_.dep_file,
                                                   configuration_.out_path,
                                                   units,
                                                   CORE_UNIT_INDEX);
    if (configuration_.is_for_dependencies) {
      return Result::invalid();
    }
  }

  if (configuration_.parse_only) return Result::invalid();

  ir::Program* ir_program = resolve(units, ENTRY_UNIT_INDEX, CORE_UNIT_INDEX);
  sort_classes(ir_program->classes());

  bool encountered_error_before_type_checks = diagnostics()->encountered_error();

  if (Flags::print_ir_tree) ir_program->print(true);

  check_types_and_deprecations(ir_program);
  post_type_check();
  check_definite_assignments_returns(ir_program, diagnostics());

  bool encountered_error = diagnostics()->encountered_error();
  if (configuration_.werror && diagnostics()->encountered_warning()) {
    encountered_error = true;
  }

  if (configuration_.is_for_analysis) {
    if (encountered_error) exit(1);
    return Result::invalid();
  }

  // If we already encountered errors before the type-check we won't be able
  // to compile the program.
  if (encountered_error_before_type_checks) {
    diagnostics()->report_error("Compilation failed");
    exit(1);
  }
  // If we encountered errors abort unless the `--force` flag is on.
  if (!configuration_.force && encountered_error) {
    diagnostics()->report_error("Compilation failed");
    exit(1);
  }

  // Only optimize the program, if we didn't encounter any errors.
  // If there was an error, we might not be able to trust the type annotations.
  bool run_optimizations = !diagnostics()->encountered_error() &&
      configuration_.optimization_level >= 1;

  SourceMapper unoptimized_source_mapper(source_manager());
  auto source_mapper = &unoptimized_source_mapper;
  TypeOracle oracle(source_mapper);
  auto program = construct_program(ir_program, source_mapper, &oracle, null, run_optimizations);

  SourceMapper optimized_source_mapper(source_manager());
  if (run_optimizations && configuration_.optimization_level >= 2) {
    bool quiet = true;
    ir_program = resolve(units, ENTRY_UNIT_INDEX, CORE_UNIT_INDEX, quiet);
    sort_classes(ir_program->classes());
    // We check the types again, because the compiler computes types as
    // a side-effect of this and the types are necessary for the
    // optimizations. This feels a little bit unfortunate, but it is
    // important that the second compilation pass where we use propagated
    // types is based on the same IR nodes, so we need the optimizations
    // to behave the same way for the output to be correct.
    check_types_and_deprecations(ir_program, quiet);
    ASSERT(!diagnostics()->encountered_error());
    TypeDatabase* types = TypeDatabase::compute(program);
    source_mapper = &optimized_source_mapper;
    program = construct_program(ir_program, source_mapper, &oracle, types, true);
    delete types;
  }

  if (propagate) {
    TypeDatabase* types = TypeDatabase::compute(program);
    auto json = types->as_json();
    printf("%s", json.c_str());
    delete types;
  }

  SnapshotGenerator generator(program);
  generator.generate(program);
  int source_map_size;
  uint8* source_map_data = source_mapper->cook(&source_map_size);
  int snapshot_size;
  uint8* snapshot = generator.take_buffer(&snapshot_size);
  return {
    .snapshot = snapshot,
    .snapshot_size = snapshot_size,
    .source_map_data = source_map_data,
    .source_map_size = source_map_size,
  };
}

} // namespace toit::compiler
} // namespace toit

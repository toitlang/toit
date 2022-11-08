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
#include "lsp/fs_connection_socket.h"
#include "lsp/fs_protocol.h"
#include "lsp/multiplex_stdout.h"
#include "lock.h"
#include "map.h"
#include "monitor.h"
#include "optimizations/optimizations.h"
#include "parser.h"
#include "resolver.h"
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

  Result run(List<const char*> source_paths);

 protected:
  virtual Source* _load_file(const char* path, const PackageLock& package_lock);
  virtual ast::Unit* parse(Source* source);
  virtual void setup_lsp_selection_handler();

  // Gives the Pipeline the opportunity to change the program once it was
  // resolved.
  virtual void patch(ir::Program* program);

  virtual void lsp_selection_import_path(const char* path,
                                         const char* segment,
                                         const char* resolved) {}
  virtual void lsp_complete_import_first_segment(ast::Identifier* segment,
                                                 const Package& current_package,
                                                 const PackageLock& package_lock) {}

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

  void _report_failed_import(ast::Import* import,
                             ast::Unit* unit,
                             const PackageLock& package_lock);
  Source* _load_import(ast::Unit* unit,
                       ast::Import* import,
                       const PackageLock& package_lock);
  std::vector<ast::Unit*> _parse_units(List<const char*> source_paths,
                                       const PackageLock& package_lock);
  ir::Program* resolve(const std::vector<ast::Unit*>& units,
                       int entry_unit_index, int core_unit_index);
  void check_types_and_deprecations(ir::Program* program);
  void set_toitdocs(const ToitdocRegistry& registry) { toitdoc_registry_ = registry; }
};

class DebugCompilationPipeline : public Pipeline {
 public:
  // Forward constructor arguments to super class.
  using Pipeline::Pipeline;

 protected:
  void patch(ir::Program* program);
  List<const char*> adjust_source_paths(List<const char*> source_paths);
  PackageLock load_package_lock(List<const char*> source_paths);

 public:
  static constexpr const char* const DEBUG_ENTRY_PATH = "///<debug>";
  static constexpr const char* const DEBUG_ENTRY_CONTENT = R"""(
import debug.debug_string show do_debug_string

// We are avoiding types to make the patching easier.
dispatch_debug_string location_token obj nested -> any:
  // Calls to the static dispatch methods will be patched in here.
  throw "Unknown location token"

main args:
  do_debug_string args:: |location_token obj nested|
    dispatch_debug_string location_token obj nested
     )""";
};

class LanguageServerPipeline : public Pipeline {
 public:
  // Forward constructor arguments to super class.
  using Pipeline::Pipeline;

 protected:
  bool is_for_analysis() const { return true; }
};

class LocationLanguageServerPipeline : public LanguageServerPipeline {
 public:
  LocationLanguageServerPipeline(const char* path,
                                 int line_number,   // 1-based
                                 int column_number, // 1-based
                                 const PipelineConfiguration& configuration)
      : LanguageServerPipeline(configuration)
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
  // Forward constructor arguments to super class.
  using LocationLanguageServerPipeline::LocationLanguageServerPipeline;

 protected:
  void setup_lsp_selection_handler();
  Source* _load_file(const char* path, const PackageLock& package_lock);



  void lsp_complete_import_first_segment(ast::Identifier* segment,
                                         const Package& current_package,
                                         const PackageLock& package_lock);
  void lsp_selection_import_path(const char* path,
                                 const char* segment,
                                 const char* resolved);

  bool is_lsp_selection_identifier() { return true; }

 private:
  Symbol completion_prefix_ = Symbol::invalid();
  std::string package_id_ = Package::INVALID_PACKAGE_ID;
};

class GotoDefinitionPipeline : public LocationLanguageServerPipeline {
 public:
  GotoDefinitionPipeline(const char* completion_path,
                         int line_number,   // 1-based
                         int column_number, // 1-based
                         const PipelineConfiguration& configuration)
      : LocationLanguageServerPipeline(completion_path, line_number, column_number,
                                       configuration) {}

 protected:
  void setup_lsp_selection_handler();

  void lsp_selection_import_path(const char* path,
                                 const char* segment,
                                 const char* resolved);

  bool is_lsp_selection_identifier() { return false; }
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
    auto source_paths = ListBuilder<const char*>::allocate(path_count + 1);
    for (int i = 0; i < path_count; i++) {
      source_paths[i] = strdup(reader.next("path"));
    }
    // Add the debug-content which would be needed for a real compilation.
    fs->register_intercepted(DebugCompilationPipeline::DEBUG_ENTRY_PATH,
                             unsigned_cast(DebugCompilationPipeline::DEBUG_ENTRY_CONTENT),
                             strlen(DebugCompilationPipeline::DEBUG_ENTRY_CONTENT));
    source_paths[path_count] = DebugCompilationPipeline::DEBUG_ENTRY_PATH;

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
    } else {
      FATAL("LANGUAGE SERVER ERROR - Mode not recognized");
    }
  }
}

void Compiler::lsp_complete(const char* source_path,
                            int line_number,
                            int column_number,
                            const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  CompletionPipeline pipeline(source_path, line_number, column_number, configuration);
  pipeline.run(ListBuilder<const char*>::build(source_path));
}

void Compiler::lsp_goto_definition(const char* source_path,
                                   int line_number,
                                   int column_number,
                                   const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  GotoDefinitionPipeline pipeline(source_path, line_number, column_number, configuration);

  pipeline.run(ListBuilder<const char*>::build(source_path));
}

void Compiler::lsp_analyze(List<const char*> source_paths,
                           const PipelineConfiguration& configuration) {
  ASSERT(configuration.diagnostics != null);
  LanguageServerPipeline pipeline(configuration);
  pipeline.run(source_paths);
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
  LanguageServerPipeline pipeline(configuration);
  pipeline.run(ListBuilder<const char*>::build(source_path));
}

static bool _sorted_by_inheritance(List<ir::Class*> classes) {
  std::vector<ir::Class*> super_hierarchy;
  ir::Class* current_super = null;
  ir::Class* last = null;
  for (auto klass : classes) {
    if (klass->super() == current_super) {
      // Do nothing.
    } else if (klass->super() == last) {
      super_hierarchy.push_back(current_super);
      current_super = last;
    } else {
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
                       const Compiler::Configuration& compiler_config) {
  // We accept '/' paths on Windows as well.
  // For simplicity (and consistency) switch to localized ones in the compiler.
  source_paths = FilesystemLocal::to_local_path(source_paths);
  bool single_source = source_paths.length() == 1;
  FilesystemHybrid fs(single_source ? source_paths[0] : null);
  SourceManager source_manager(&fs);
  AnalysisDiagnostics diagnostics(&source_manager, compiler_config.show_package_warnings);
  PipelineConfiguration configuration = {
    .out_path = null,
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
    .is_for_analysis = true,
  };
  Pipeline pipeline(configuration);
  pipeline.run(source_paths);
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
  CompilationDiagnostics diagnostics(&source_manager, compiler_config.show_package_warnings);

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
  };

  return compile(source_path, configuration);
}

SnapshotBundle Compiler::compile(const char* source_path,
                                 const PipelineConfiguration& configuration) {
  PipelineConfiguration main_configuration = configuration;

  NullDiagnostics null_diagnostics(configuration.source_manager);
  PipelineConfiguration debug_configuration = main_configuration;
  debug_configuration.diagnostics = &null_diagnostics;
  // TODO(florian): the dep-file needs to keep track of both compilations.
  debug_configuration.dep_file = null;
  debug_configuration.dep_format = DepFormat::none;

  auto source_paths = ListBuilder<const char*>::build(source_path);

  auto pipeline_main_result = Pipeline::Result::invalid();
  auto pipeline_debug_result = Pipeline::Result::invalid();

  if (Flags::no_fork) {
    if (Flags::compiler_sandbox) {
      fprintf(stderr, "Can't specify separate compiler sandbox with no_fork option\n");
      exit(1);
    }
    Pipeline main_pipeline(main_configuration);
    pipeline_main_result = main_pipeline.run(source_paths);
    if (pipeline_main_result.is_valid()) {
      DebugCompilationPipeline debug_pipeline(debug_configuration);
      pipeline_debug_result = debug_pipeline.run(source_paths);
    }
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
      auto pipeline_result = pipeline.run(source_paths);
      send_pipeline_result(write_fd, pipeline_result);
      if (pipeline_result.is_valid()) {
        DebugCompilationPipeline debug_pipeline(debug_configuration);
        pipeline_result = debug_pipeline.run(source_paths);
        send_pipeline_result(write_fd, pipeline_result);
      }
      close(write_fd);
      exit(0);
    }
    close(write_fd);  // Not needing that direction.
    pipeline_main_result = receive_pipeline_result(read_fd);
    if (pipeline_main_result.is_valid()) {
      pipeline_debug_result = receive_pipeline_result(read_fd);
    }
    close(read_fd);
    wait_for_child(cpid, main_configuration.diagnostics);
#else
    FATAL("fork not supported");
#endif
  }
  if (!pipeline_main_result.is_valid() || !pipeline_debug_result.is_valid()) {
    // We don't create the debug-result if the main-result failed, and
    // the debug-compilation should never fail. The following frees should thus
    // not be necessary. However, they can't hurt either.
    pipeline_main_result.free_all();
    pipeline_debug_result.free_all();
    return SnapshotBundle::invalid();
  }
  SnapshotBundle result(List<uint8>(pipeline_main_result.snapshot,
                                    pipeline_main_result.snapshot_size),
                        List<uint8>(pipeline_main_result.source_map_data,
                                    pipeline_main_result.source_map_size),
                        List<uint8>(pipeline_debug_result.snapshot,
                                    pipeline_debug_result.snapshot_size),
                        List<uint8>(pipeline_debug_result.source_map_data,
                                    pipeline_debug_result.source_map_size));
  // The snapshot bundle copies all given data. It's thus safe to free
  //   the pipeline data.
  pipeline_main_result.free_all();
  pipeline_debug_result.free_all();
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

ir::Program* Pipeline::resolve(const std::vector<ast::Unit*>& units,
                               int entry_unit_index, int core_unit_index) {
  // Resolve all units.
  Resolver resolver(configuration_.lsp, source_manager(), diagnostics());
  auto result = resolver.resolve(units,
                                 entry_unit_index,
                                 core_unit_index);
  set_toitdocs(resolver.toitdocs());
  return result;
}

void Pipeline::patch(ir::Program* program) {}

void DebugCompilationPipeline::patch(ir::Program* program) {
  // Patches the dispatch_debug_string method that was given in the DEBUG_ENTRY_PATH.
  // The method receives 3 parameters:
  //   - the location_token
  //   - a JSON object
  //   - a lambda for nested deserialization
  // The method should dispatch to the `debug_string` method of the class that
  // corresponds to the location_token.
  // We therefore find all static `Class.debug_string` methods, and add an `if`
  //   that checks whether the `location_token` is the same as the `Class`' token.
  //   If yes, we call that method, passing the JSON object and the lambda.
  ir::Method* dispatch_method = null;
  for (auto method : program->methods()) {
    if (method->name() == Symbols::dispatch_debug_string) {
      auto location = source_manager()->compute_location(method->range().from());
      if (strcmp(location.source->absolute_path(), DEBUG_ENTRY_PATH) == 0) {
        dispatch_method = method;
        break;
      }
    }
  }
  ASSERT(dispatch_method != null);
  auto range = dispatch_method->range();
  ir::Parameter* location_token_param = dispatch_method->parameters()[0];
  ir::Parameter* obj_param = dispatch_method->parameters()[1];
  ir::Parameter* nested_callback_param = dispatch_method->parameters()[2];
  ListBuilder<ir::Expression*> dispatch_statements;
  CallShape call_shape(2, 0);
  for (auto method : program->methods()) {
    auto klass = method->holder();
    if (klass == null) continue;
    if (method->name() != Symbols::debug_string) continue;
    if (!method->is_global_fun()) continue;  // Exclude constructors and factories.
    auto shape = method->resolution_shape();
    if (!shape.accepts(call_shape)) continue;
    // We now have a static `Class.debug_string` method with the right shape.
    // Add the following `if` to the body:
    // ```
    // if <Class-location-token> == location_token: return <Class.debug_string> object nested
    // ```
    CallBuilder builder(range);  // The `<Class.debug-string> object nested` call.
    builder.add_argument(_new ir::ReferenceLocal(obj_param, 0, range),
                              Symbol::invalid());
    builder.add_argument(_new ir::ReferenceLocal(nested_callback_param, 0, range),
                              Symbol::invalid());
    auto call = builder.call_static(_new ir::ReferenceMethod(method, range));
    CallBuilder comparison_builder(range);  // `<Class-location-token> == location_token`.
    comparison_builder.add_argument(_new ir::ReferenceLocal(location_token_param, 0, range),
                                    Symbol::invalid());
    int class_location_token = klass->range().from().token();
    auto dot = _new ir::Dot(_new ir::LiteralInteger(class_location_token, range),
                            Token::symbol(Token::EQ));
    auto comparison_call = comparison_builder.call_instance(dot);
    dispatch_statements.add(_new ir::If(comparison_call,
                                        _new ir::Return(call, 0, range),
                                        _new ir::LiteralNull(range),
                                        range));
  }
  dispatch_statements.add(dispatch_method->body());
  dispatch_method->replace_body(_new ir::Sequence(dispatch_statements.build(), range));
}

void Pipeline::check_types_and_deprecations(ir::Program* program) {
  ::toit::compiler::check_types_and_deprecations(program, configuration_.lsp, toitdocs(), diagnostics());
}

List<const char*> Pipeline::adjust_source_paths(List<const char*> source_paths) {
  auto fs_entry_path = filesystem()->entry_path();
  if (fs_entry_path != null) {
    // The filesystem can override the entry path.
    source_paths = ListBuilder<const char*>::build(fs_entry_path);
  }
  return source_paths;
}

List<const char*> DebugCompilationPipeline::adjust_source_paths(List<const char*> source_paths) {
  source_paths = Pipeline::adjust_source_paths(source_paths);
  ASSERT(source_paths.length() == 1);
  // We should use the SourceManager's VIRTUAL_FILE_PREFIX, but hard-coding it is
  // much simpler, and we do have an ASSERT to make sure we update if the prefix
  // ever changes.
  ASSERT(SourceManager::is_virtual_file(DEBUG_ENTRY_PATH));
  filesystem()->register_intercepted(DEBUG_ENTRY_PATH, unsigned_cast(DEBUG_ENTRY_CONTENT), strlen(DEBUG_ENTRY_CONTENT));
  source_paths = ListBuilder<const char*>::build(DEBUG_ENTRY_PATH, source_paths[0]);
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

PackageLock DebugCompilationPipeline::load_package_lock(const List<const char*> source_paths) {
  // When doing the debug-compilation, the actual entry file has been pushed back (and the
  //   synthetic main has been inserted in front). The lock file should still be found
  //   relative to the original path.
  ASSERT(source_paths.length() == 2);
  auto entry_path = source_paths[1];
  auto lock_file = find_lock_file(entry_path, filesystem());
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

  // We only provide completions after a `-` if we are after a " --".
  if (offset >= 1 && text[offset - 1] == '-') {
    if (offset < 3 ||
        text[offset - 1] != '-' ||
        text[offset - 2] != '-' ||
        text[offset - 3] != ' ') {
      exit(0);
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

  package_id_ = package_lock.package_for(path, filesystem()).id();

  const uint8* text = result->text();
  int offset = compute_source_offset(text, line_number_, column_number_);
  int start_offset = offset;
  while (start_offset > 0 && is_identifier_part(text[start_offset - 1])) {
    start_offset--;
  }

  if (start_offset == offset || !is_identifier_start(text[start_offset])) {
    completion_prefix_ = Symbols::empty_string;
  } else {
    auto canonicalized = symbol_canonicalizer()->canonicalize_identifier(&text[start_offset], &text[offset]);
    if (canonicalized.kind == Token::Kind::IDENTIFIER) {
      completion_prefix_ = canonicalized.symbol;
    } else {
      completion_prefix_ = Token::symbol(canonicalized.kind);
    }
  }
  return result;
}

void CompletionPipeline::setup_lsp_selection_handler() {
  lsp()->setup_completion_handler(completion_prefix_, package_id_, source_manager());
}


void CompletionPipeline::lsp_complete_import_first_segment(ast::Identifier* segment,
                                                           const Package& current_package,
                                                           const PackageLock& package_lock) {
  lsp()->complete_first_segment(completion_prefix_,
                                segment,
                                current_package,
                                package_lock);
}

void CompletionPipeline::lsp_selection_import_path(const char* path,
                                                   const char* segment,
                                                   const char* resolved) {
  lsp()->complete_import_path(completion_prefix_, path, filesystem());
}

void GotoDefinitionPipeline::setup_lsp_selection_handler() {
  lsp()->setup_goto_definition_handler(source_manager());
}

void GotoDefinitionPipeline::lsp_selection_import_path(const char* path,
                                                       const char* segment,
                                                       const char* resolved) {
  lsp()->goto_definition_import_path(resolved);
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

// Provides a better error message for failed imports.
void Pipeline::_report_failed_import(ast::Import* import,
                                     ast::Unit* unit,
                                     const PackageLock& package_lock) {
  auto segments = import->segments();
  // Rebuild the path, without replacing the "." with "/" for a good
  // error message.
  std::string error_path;
  if (import->is_relative()) {
    error_path += '.';
    for (int i = 0; i < import->dot_outs(); i++) error_path += '.';
  }
  for (int i = 0; i < segments.length(); i++) {
    if (i != 0) error_path += '.';
    error_path += segments[i]->data().c_str();
  }

  // We are duplicating a lot of the work we did in the import loader.
  // However, this time we look at each segment separately to figure out at which
  // point things go wrong.
  auto fs = filesystem();
  auto unit_package = package_lock.package_for(unit->absolute_path(), filesystem());
  // Package used to create a relative path for the path in the note.
  Package build_error_package = Package::invalid();
  auto build_error_path = [&](const std::string& path) {
    return build_error_package.build_error_path(filesystem(), path);
  };

  PathBuilder path_builder(filesystem());
  bool have_note = false;
  std::function<void ()> note_fun;

  int segment_start = 0;
  if (import->is_relative()) {
    build_error_package = unit_package;
    path_builder.add(unit->absolute_path());
    path_builder.join("..");  // Dot the unit filename away.
    for (int i = 0; i < import->dot_outs(); i++) {
      path_builder.join("..");
    }
    path_builder.canonicalize();
  } else {
    auto module_name = segments[0]->data();
    auto import_package = package_lock.resolve_prefix(unit_package, std::string(module_name.c_str()));
    ASSERT(import_package.is_valid() && import_package.error_state() == Package::OK);
    if (!import_package.is_sdk_prefix()) segment_start = 1;
    // The lock-file reader already checked that all packages exist.
    ASSERT(fs->is_directory(import_package.absolute_path().c_str()));
    build_error_package = import_package;
    path_builder.add(import_package.absolute_path());
  }
  for (int i = segment_start; i < segments.length(); i++) {
    path_builder.join(segments[i]->data().c_str());
    if (i < segments.length() - 1) {
      // Check if that path fails.
      std::string built = path_builder.buffer();
      if (!fs->exists(built.c_str()) || !fs->is_directory(built.c_str())) {
        auto note_node = segments[i];
        const char* note_message = fs->exists(built.c_str())
            ? "Not a folder: '%s'"
            : "Folder does not exist: '%s'";
        auto note_path = build_error_path(built);
        note_fun = [=]() {
          diagnostics()->report_note(note_node,
                                     note_message,
                                     note_path.c_str());
        };
        have_note = true;
        break;
      }
    }
  }
  int length_after_segments = path_builder.length();
  if (!have_note) {
    auto note_node = segments.last();
    // We need to append '.toit', or duplicate the last segment.
    path_builder.add(".toit");
    auto built = path_builder.buffer();
    // We would have reported an error earlier if the path existed, but wasn't valid.
    ASSERT(!fs->exists(built.c_str()));
    auto toit_path = path_builder.buffer();
    path_builder.reset_to(length_after_segments);
    auto potential_dir = path_builder.buffer();
    path_builder.join(segments.last()->data().c_str());
    path_builder.add(".toit");
    auto toit_in_dir = path_builder.buffer();

    if (fs->exists(potential_dir.c_str()) && fs->is_directory(potential_dir.c_str())) {
      auto note_path = build_error_path(potential_dir);
      // This file must not exist, as we would have reported an error
      // earlier, otherwise.
      ASSERT(!fs->exists(toit_in_dir.c_str()) || !fs->is_regular_file(toit_in_dir.c_str()));
      auto toit_file = std::string(segments.last()->data().c_str()) + ".toit";
      note_fun = [=]() {
        diagnostics()->report_note(note_node,
                                    "Folder '%s' exists, but is missing a '%s' file",
                                    note_path.c_str(),
                                    toit_file.c_str());
      };
    } else {
      auto note_path1 = build_error_path(toit_path);
      auto note_path2 = build_error_path(toit_in_dir);
      note_fun = [=]() {
        diagnostics()->report_note(note_node,
                                    "Missing library file. Tried '%s' and '%s'",
                                    note_path1.c_str(),
                                    note_path2.c_str());
      };
    }
  }
  diagnostics()->start_group();
  diagnostics()->report_error(import, "Failed to find import '%s'", error_path.c_str());
  note_fun();
  diagnostics()->end_group();
}

/// Extracts the path for the [import] that is contained in [unit].
/// Returns null if the import couldn't be found or if there was an error.
/// Returns the corresponding source, otherwise.
Source* Pipeline::_load_import(ast::Unit* unit,
                               ast::Import* import,
                               const PackageLock& package_lock) {
  if (unit->source() == null) FATAL("unit without source");

  if (SourceManager::is_virtual_file(unit->absolute_path()) && import->is_relative()) {
    diagnostics()->report_error(import, "Relative import not possible from virtual file.");
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

  std::string expected_import_package_id;
  PathBuilder import_path_builder(filesystem());
  int relative_segment_start = 0;
  bool dotted_out = false;
  if (is_relative) {
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
      lsp_complete_import_first_segment(module_segment, unit_package, package_lock);
      // Otherwise still mark that we had an LSP segment, as we might need it for
      // goto-definition. That one doesn't care for the values, as it only looks
      // at the result value.
      lsp_path = "",
      lsp_segment = module_segment->data().c_str();
    }
    auto resolved = package_lock.resolve_prefix(unit_package, prefix);
    auto error_range = module_segment->range();
    switch (resolved.error_state()) {
      case Package::OK:
        // All good.
        break;

      case Package::INVALID:
        if (package_lock.has_errors()) {
          diagnostics()->report_error(error_range,
                                      "Package for prefix '%s' not found, but lock file has errors",
                                      prefix.c_str());
        } else {
          diagnostics()->report_error(error_range,
                                      "Package for prefix '%s' not found",
                                      prefix.c_str());
        }
        return null;

      case Package::ERROR:
        diagnostics()->report_error(error_range,
                                    "Package for prefix '%s' not found due to error in lock file",
                                    prefix.c_str());
        return null;

      case Package::NOT_FOUND:
        diagnostics()->report_error(error_range,
                                    "Package '%s' for prefix '%s' not found",
                                    resolved.id().c_str(),
                                    prefix.c_str());
        return null;
    }
    expected_import_package_id = resolved.id();
    import_path_builder.join(resolved.absolute_path());
    relative_segment_start = resolved.is_sdk_prefix() ? 0 : 1;
    ASSERT(import_path_builder[import_path_builder.length() - 1] != '/');
  }
  for (int i = relative_segment_start; i < segments.length(); i++) {
    auto segment = segments[i];
    if (segment->is_LspSelection()) {
      lsp_path = import_path_builder.strdup();
      lsp_segment = segment->data().c_str();
    }
    import_path_builder.join(segment->data().c_str());
  }

  int length_after_segments = import_path_builder.length();
  Source* result = null;
  auto result_package = Package::invalid();
  bool already_reported_error = false;
  for (int j = 0; j < 2; j++) {
    import_path_builder.reset_to(length_after_segments);
    if (j == 1) {
      // In the second run we see if the import points to a directory in which
      // case we duplicate the segment:
      // `import foo` then looks for `foo/foo.toit`.
      const char* last_segment = segments[segments.length() - 1]->data().c_str();
      import_path_builder.join(last_segment);
    }
    import_path_builder.add(".toit");
    // TODO(florian): in order to show `<pkg1>` messages we can't have long package-ids. Currently
    // they are something like `package-github.com/toitware/my_package`.
    std::string import_path = import_path_builder.buffer();
    result_package = package_lock.package_for(import_path, filesystem());
    auto load_result = source_manager()->load_file(import_path, result_package);
    switch (load_result.status) {
      case SourceManager::LoadResult::OK:
        result = load_result.source;
        goto break_loop;

      case SourceManager::LoadResult::NOT_FOUND:
        // Do nothing.
        break;

      case SourceManager::LoadResult::NOT_REGULAR_FILE:
      case SourceManager::LoadResult::FILE_ERROR:
        load_result.report_error(import->range(), diagnostics());
        already_reported_error = true;
        // Don't return just yet, but give the lsp handler an opportunity to run.
        goto break_loop;
    }
    if (result != null) break;
  }
  break_loop:

  if (lsp_path != null) {
    lsp_selection_import_path(lsp_path,
                              lsp_segment,
                              result == null ? null : result->absolute_path());
  }

  if (result == null && already_reported_error) return null;

  if (result == null) {
    _report_failed_import(import, unit, package_lock);
  } else {
    ASSERT(result_package.is_ok());
    if (result_package.id() != expected_import_package_id) {
      if (!dotted_out) {  // If we dotted out, then we already reported an error.
        // We ended up in a nested package.
        // In theory we could allow this, but it feels brittle.
        diagnostics()->report_error(import, "Import traverses package boundary: '%s'", import_path_builder.c_str());
      }
    }
  }

  return result;
}

Source* Pipeline::_load_file(const char* path, const PackageLock& package_lock) {
  PathBuilder builder(filesystem());
  if (filesystem()->is_absolute(path)) {
    builder.join(path);
  } else {
    builder.join(filesystem()->cwd());
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

static void mark_eager_globals(List<ir::Global*> globals) {
  for (auto global : globals) {
    auto body = global->body();
    if (!body->is_Return()) continue;
    auto value = body->as_Return()->value();
    if (value->is_Literal()) {
      ASSERT(!value->is_LiteralUndefined());
      global->mark_eager();
    }
  }
}

static void check_sdk(const std::string& constraint, Diagnostics* diagnostics) {
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
  };
}

Pipeline::Result Pipeline::run(List<const char*> source_paths) {
  auto fs = configuration_.filesystem;
  fs->initialize(diagnostics());
  source_paths = adjust_source_paths(source_paths);
  auto package_lock = load_package_lock(source_paths);

  if (package_lock.sdk_constraint() != "") {
    // TODO(florian): we should be able to continue compiling even with
    // a wrong SDK.
    check_sdk(package_lock.sdk_constraint(), diagnostics());
  }

  auto units = _parse_units(source_paths, package_lock);

  if (configuration_.dep_file != null) {
    ASSERT(configuration_.dep_format != Compiler::DepFormat::none);
    PlainDepWriter plain_writer;
    NinjaDepWriter ninja_writer;
    DepWriter* chosen_writer = null;
    switch (configuration_.dep_format) {
      case Compiler::DepFormat::plain:
        chosen_writer = &plain_writer;
        break;
      case Compiler::DepFormat::ninja:
        chosen_writer = &ninja_writer;
        break;
      case Compiler::DepFormat::none:
        UNREACHABLE();
    }
    chosen_writer->write_deps_to_file_if_different(configuration_.dep_file,
                                                   configuration_.out_path,
                                                   units,
                                                   CORE_UNIT_INDEX);
  }

  if (configuration_.parse_only) return Result::invalid();

  setup_lsp_selection_handler();

  ir::Program* ir_program = resolve(units, ENTRY_UNIT_INDEX, CORE_UNIT_INDEX);

  bool encountered_error_before_type_checks = diagnostics()->encountered_error();

  if (Flags::print_ir_tree) ir_program->print(true);

  patch(ir_program);
  check_types_and_deprecations(ir_program);
  check_definite_assignments_returns(ir_program, diagnostics());

  if (configuration_.is_for_analysis) {
    if (diagnostics()->encountered_error()) exit(1);
    return Result::invalid();
  }

  // If we already encountered errors before the type-check we won't be able
  // to compile the program.
  if (encountered_error_before_type_checks) {
    printf("Compilation failed.\n");
    exit(1);
  }
  // If we encountered errors abort unless the `--force` flag is on.
  bool encountered_error = diagnostics()->encountered_error();
  if (configuration_.werror && diagnostics()->encountered_warning()) {
    encountered_error = true;
  }
  if (!configuration_.force && encountered_error) {
    printf("Compilation failed.\n");
    exit(1);
  }

  SourceMapper source_mapper(source_manager());

  source_mapper.register_selectors(ir_program->classes());

  add_lambda_boxes(ir_program);
  add_monitor_locks(ir_program);
  add_stub_methods_and_switch_to_plain_shapes(ir_program);
  add_interface_stub_methods(ir_program);

  ASSERT(_sorted_by_inheritance(ir_program->classes()));

  // Only optimize the program, if we didn't encounter any errors.
  // If there was an error, we might not be able to trust the type annotations.
  if (!diagnostics()->encountered_error()) {
    optimize(ir_program);
  }
  tree_shake(ir_program);

  // We assign the field ids very late in case we can inline field-accesses.
  assign_field_indexes(ir_program->classes());
  // Similarly, assign the global ids at the end, in case they can be tree
  // shaken or inlined.
  assign_global_ids(ir_program->globals());

  // Mark globals that can be accessed directly without going through the
  //   lazy getter.
  mark_eager_globals(ir_program->globals());

  Backend backend(source_manager(), &source_mapper);
  auto program = backend.emit(ir_program);
  SnapshotGenerator generator(program);
  generator.generate(program);
  int source_map_size;
  uint8* source_map_data = source_mapper.cook(&source_map_size);
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

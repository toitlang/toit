// Copyright (C) 2021 Toitware ApS.
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

#include <errno.h>
#include <libgen.h>

#include "../top.h"
#include "../flags.h"
#include "compiler.h"
#include "executable.h"

namespace toit {
namespace compiler {

static void print_usage(int exit_code) {
  // We don't expose the `--lsp` flag in the help. It's internal and not
  // relevant for users.
  printf("Usage:\n");
  printf("toit\n");
  printf("  [-h] [--help]                         // This help message\n");
  printf("  [--version]                           // Prints version information\n");
  printf("  [-X<flag>]*                           // Provide a compiler flag\n");
  printf("  [--dependency-file <file>]            // Write a dependency file ('-' for stdout)\n");
  printf("  [--dependency-format {plain|ninja}]   // The format of the dependency file\n");
  printf("  [--project-root <path>]               // Path to the project root. Any package.lock file must be in that folder\n");
  printf("  [--force]                             // Finish compilation even with errors (if possible).\n");
  printf("  [-Werror]                             // Treat warnings like errors.\n");
  printf("  [--show-package-warnings]             // Show warnings from packages.\n");
  printf("  { -o <executable> <toitfile> |        // Write executable.\n");
  printf("    -w <snapshot> <toitfile>            // Write snapshot file.\n");
  printf("    --analyze <toitfiles>...            // Analyze Toit files.\n");
  printf("  }\n");
  exit(exit_code);
}

// Prints the version and exits.
static void print_version() {
  printf("Toit version: %s\n", vm_git_version());
  exit(0);
}

int main(int argc, char **argv) {
  Flags::process_args(&argc, argv);

  int exit_state = 0;

  OS::set_up();

  if (argc < 2) print_usage(1);

  // Help must be used on its own.
  if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
    if (argc != 2) {
      fprintf(stderr, "Can't have options with '%s'\n", argv[1]);
      print_usage(1);
    }
    print_usage(0);
  }

  // Version must be used on its own.
  if (strcmp(argv[1], "--version") == 0) {
    if (argc != 2) {
      fprintf(stderr, "Can't have options with '%s'\n", argv[1]);
      print_usage(1);
    }
    print_version();
  }

  char* bundle_filename = null;
  char* exe_filename = null;

  int source_path_count = 0;
  const char* source_path;
  // By default source_paths just points to the single source path.
  // For the multi-case (when we analyze), we will switch the pointer
  //   to the argv array.
  const char** source_paths = &source_path;

  char** args = null;
  const char* direct_script = null;
  bool force = false;
  bool werror = false;
  bool show_package_warnings = false;
  const char* dep_file = null;
  const char* project_root = null;
  auto dep_format = compiler::Compiler::DepFormat::none;
  bool for_language_server = false;
  bool for_analysis = false;

  int processed_args = 1;  // The executable name has already been processed.

  int ways_to_run = 0;
  while (processed_args < argc) {
    if (strcmp(argv[processed_args], "-h") == 0 ||
        strcmp(argv[processed_args], "--help") == 0 ||
        strcmp(argv[processed_args], "--version") == 0) {
      fprintf(stderr,
              "The '%s' flag must not be used in combination with other arguments\n",
              argv[processed_args]);
      print_usage(1);
    }
    if (strcmp(argv[processed_args], "-w") == 0) {
      // Bundle writing.
      processed_args++;
      if (processed_args == argc) {
        fprintf(stderr, "Missing argument to '-w'\n");
        print_usage(1);
      }
      if (bundle_filename != null) {
        fprintf(stderr, "Only one '-w' flag is allowed.\n");
        print_usage(1);
      }
      bundle_filename = argv[processed_args++];
    } else if (strcmp(argv[processed_args], "-o") == 0) {
      // Generating an executable.
      processed_args++;
      if (processed_args == argc) {
        fprintf(stderr, "Missing argument to '-o'\n");
        print_usage(1);
      }
      if (exe_filename != null) {
        fprintf(stderr, "Only one '-o' flag is allowed.\n");
        print_usage(1);
      }
      exe_filename = argv[processed_args++];
    } else if (strcmp(argv[processed_args], "--force") == 0) {
      force = true;
      processed_args++;
    } else if (strcmp(argv[processed_args], "-Werror") == 0) {
      werror = true;
      processed_args++;
    } else if (strcmp(argv[processed_args], "--show-package-warnings") == 0) {
      show_package_warnings = true;
      processed_args++;
    } else if (strcmp(argv[processed_args], "--dependency-file") == 0) {
      processed_args++;
      if (processed_args == argc) {
        fprintf(stderr, "Missing argument to '--dependency-file'\n");
        print_usage(1);
      }
      if (dep_file != null) {
        fprintf(stderr, "Only one '--dependency-file' flag is allowed.\n");
        print_usage(1);
      }
      dep_file = argv[processed_args++];
    } else if (strcmp(argv[processed_args], "--dependency-format") == 0) {
      processed_args++;
      if (processed_args == argc) {
        fprintf(stderr, "Missing argument to '--dependency-format'\n");
        print_usage(1);
      }
      if (dep_format != compiler::Compiler::DepFormat::none) {
        fprintf(stderr, "Only one '--dependency-format' flag is allowed.\n");
        print_usage(1);
      }
      if (strcmp(argv[processed_args], "plain") == 0) {
        dep_format = compiler::Compiler::DepFormat::plain;
      } else if (strcmp(argv[processed_args], "ninja") == 0) {
        dep_format = compiler::Compiler::DepFormat::ninja;
      } else {
        fprintf(stderr, "Unknown dependency format '%s'\n", argv[processed_args]);
        print_usage(1);
      }
      processed_args++;
    } else if (strcmp(argv[processed_args], "--project-root") == 0) {
      processed_args++;
      if (processed_args == argc) {
        fprintf(stderr, "Missing argument to '--project-root'\n");
        print_usage(1);
      }
      if (project_root != null) {
        fprintf(stderr, "Only one '--project-root' flag is allowed.\n");
        print_usage(1);
      }
      project_root = argv[processed_args++];
    } else if (strcmp(argv[processed_args], "--lsp") == 0 ||
                strcmp(argv[processed_args], "--analyze") == 0) {
      for_language_server = strcmp(argv[processed_args], "--lsp") == 0;
      for_analysis = strcmp(argv[processed_args], "--analyze") == 0;
      processed_args++;
      ways_to_run++;
    } else if (argv[processed_args][0] == '-' &&
                strcmp(argv[processed_args], "--") != 0) {
      fprintf(stderr, "Unknown flag '%s'\n", argv[processed_args]);
      print_usage(1);
    } else {
      if (strcmp(argv[processed_args], "--") == 0) processed_args++;
      if (ways_to_run == 0) {
        ASSERT(!for_analysis);  // Otherwise ways_to_run would be 1.
        if (processed_args == argc) {
          fprintf(stderr, "Missing toit-file, snapshot, or string-expression\n");
          print_usage(1);
        }
        ways_to_run++;
        ASSERT(source_path_count == 0);
        source_path = argv[processed_args++];
        source_path_count = 1;
      }
      break;
    }
  }

  // We break after the first argument that isn't a flag.
  // This means that there is always at most one source-file.
  if (ways_to_run != 1) {
    if (for_analysis) {
      ASSERT(direct_script != null);
      fprintf(stderr, "Can't analyze string expressions\n");
    } else {
      fprintf(stderr, "Toit-file, snapshot, or string-expressions are exclusive\n");
    }
    print_usage(1);
  }

  args = &argv[processed_args];

  if (for_language_server || for_analysis) {
    if (bundle_filename != null) {
      fprintf(stderr, "Can't have snapshot-name with '--analyze' or '--lsp'\n");
      print_usage(1);
    }
    if (for_language_server) {
      if (args[0] != NULL) {
        fprintf(stderr, "Language server can't have arguments\n");
        print_usage(1);
      }
    } else {
      if (args[0] == NULL) {
        fprintf(stderr, "Missing toit-files to '--analyze'\n");
        print_usage(1);
      }
      // Add all remaining arguments to the `--analyze` as source paths.
      source_paths = const_cast<const char**>(args);
      source_path_count = argc - processed_args;
      // We are not using the `args` local anymore, but it feels cleaner to set it
      //   to the end of the argv list.
      args = &argv[argc];
    }
  }
  if ((dep_file == null) != (dep_format == compiler::Compiler::DepFormat::none)) {
    fprintf(stderr, "When writing dependencies, both '--dependency-file' and '--dependency-format' must be provided\n");
    print_usage(1);
  }
  if (dep_format == compiler::Compiler::DepFormat::ninja && bundle_filename == null && exe_filename == null) {
    fprintf(stderr, "Ninja dependency-format can only be used when compiling a snapshot or an executable\n");
    print_usage(1);
  }

  if (for_language_server && dep_file != null) {
    fprintf(stderr, "Can't generate dependency file with --lsp\n");
    print_usage(1);
  }

  compiler::Compiler::Configuration compiler_config = {
    .dep_file = dep_file,
    .dep_format = dep_format,
    .project_root = project_root,
    .force = force,
    .werror = werror,
    .show_package_warnings = show_package_warnings,
  };

  if (for_language_server) {
    compiler::Compiler compiler;
    compiler.language_server(compiler_config);
  } else if (for_analysis) {
    compiler::Compiler compiler;
    compiler.analyze(List<const char*>(source_paths, source_path_count),
                      compiler_config);
  } else if (bundle_filename != null || exe_filename != null) {
    auto compiled = SnapshotBundle::invalid();
    compiler::Compiler compiler;
    auto source_path = source_path_count == 0 ? null : source_paths[0];
    compiled = compiler.compile(source_path,
                                direct_script,
                                bundle_filename == null ? exe_filename : bundle_filename,
                                compiler_config);

    if (bundle_filename != null) {
      if (!compiled.write_to_file(bundle_filename)) {
        print_usage(1);
      }
    } else {
      exit_state = create_executable(exe_filename, compiled);
    }
    free(compiled.buffer());
  } else {
    fprintf(stderr, "invalid argument\n");
    print_usage(1);
  }

  OS::tear_down();
  return exit_state;
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  return toit::compiler::main(argc, argv);
}

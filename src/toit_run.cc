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

#include "top.h"
#include "flags.h"
#include "memory.h"
#include "process.h"
#include "flash_registry.h"
#include "interpreter.h"
#include "scheduler.h"
#include "vm.h"
#include "os.h"
#include "printing.h"
#include "run.h"
#include "snapshot.h"
#include "snapshot_bundle.h"
#include "verifier.h"
#include "bytecodes.h"
#include "utils.h"
#include "main_utf_8_helper.h"
#include "compiler/compiler.h"
#include "third_party/dartino/gc_metadata.h"

#include "objects_inline.h"

#include <errno.h>
#include <libgen.h>

namespace toit {

static void print_usage(int exit_code) {
  // We don't expose the `--lsp` flag in the help. It's internal and not
  // relevant for users.
  // We don't expose the `-b` flag, to change the boot snapshot.
  printf("Usage:\n");
  printf("toit\n");
  printf("  [-h] [--help]                        // This help message.\n");
  printf("  [--version]                          // Prints version information.\n");
  printf("  [--untrusted]                        // Run the program as an untrusted (sandboxed) container.\n");
  printf("  [-O<level>]                          // Set optimization level (default = 1).\n");
  printf("  [-X<flag>]*                          // Provide a compiler flag.\n");
  printf("  [--dependency-file <file>]           // Write a dependency file ('-' for stdout).\n");
  printf("  [--dependency-format {plain|ninja}]  // The format of the dependency file.\n");
  printf("  [--project-root <path>]              // Path to the project root. Any package.lock file must be in that folder.\n");
  printf("  [--force]                            // Finish compilation even with errors (if possible).\n");
  printf("  [-Werror]                            // Treat warnings like errors.\n");
  printf("  [--show-package-warnings]            // Show warnings from packages.\n");
  printf("  { <snapshot> <args>... |             // Run snapshot file.\n");
  printf("    <toitfile> <args>... |             // Run Toit file.\n");
  printf("    -w <snapshot> <toitfile> |         // Write snapshot file.\n");
  printf("    -s <expression> |                  // Evaluate Toit expression.\n");
  printf("    --analyze <toitfiles>...           // Analyze Toit files.\n");
  printf("  }\n");
  exit(exit_code);
}

// Prints the version and exits.
static void print_version() {
  printf("Toit version: %s\n", vm_git_version());
  exit(0);
}

static bool is_binary_file(const char* path) {
  FILE* file = fopen(path, "rb");
  if (file == null) return false;
  const int BUFFER_SIZE = 128;
  uint8 buffer[BUFFER_SIZE];
  size_t bytes = fread(char_cast(buffer), 1, BUFFER_SIZE, file);
  bool is_text = Utils::is_valid_utf_8(buffer, bytes);
  fclose(file);
  return !is_text;
}

extern "C" {
  extern unsigned char toit_run_snapshot[];
  extern unsigned int toit_run_snapshot_len;
};

#define BYTECODE_LENGTH(name, length, format, print) length,
static const int opcode_length[] = { BYTECODES(BYTECODE_LENGTH) };
#undef BYTECODE_LENGTH
#define BYTECODE_NAME(name, length, format, print) #name,
static const char* const opcode_name[] = { BYTECODES(BYTECODE_NAME) };
#undef BYTECODE_NAME

static void print_verify_usage() {
  fprintf(stderr,
      "Usage: toit.run --verify [options] (<snapshot> | --system)\n"
      "  -q, -v, -vv, -vvv      Verbosity (default -v: summary on stderr).\n"
      "  --trusted              Use the rules for trusted programs (allow HALT 2/3).\n"
      "  --strict               Unproven field receivers are errors.\n"
      "  --primitives           Print the set of referenced primitives.\n"
      "  --system               Verify the embedded system snapshot.\n"
      "  --corrupt=<bci>:<byte> Patch one byte of the bytecodes before verifying.\n"
      "  --fuzz=<n>             Verify n single-byte mutations of the bytecodes.\n"
      "  --dump=<method id>     Disassemble a method.\n"
      "  --emit-bytecodes=<f>   Write the raw program bytecodes to the file and exit.\n"
      "  --emit-coverage=<f>    Write per-byte reachability (1=opcode, 2=operand) and exit.\n");
}

// Loads the snapshot, optionally corrupts bytecodes, and runs the verifier.
// Returns the process exit code: 0 if the program is accepted, 1 if it is
// rejected, 2 for usage errors.
static int verify_snapshot(int argc, char** argv) {
  VerifierOptions options;
  options.verbosity = 1;
  bool system = false;
  int corrupt_bci = -1;
  int corrupt_value = 0;
  int fuzz = 0;
  int dump = -1;
  const char* emit_bytecodes = null;
  const char* emit_coverage = null;
  const char* path = null;
  for (int i = 0; i < argc; i++) {
    if (strcmp(argv[i], "-q") == 0) options.verbosity = 0;
    else if (strcmp(argv[i], "-v") == 0) options.verbosity = 1;
    else if (strcmp(argv[i], "-vv") == 0) options.verbosity = 2;
    else if (strcmp(argv[i], "-vvv") == 0) options.verbosity = 3;
    else if (strcmp(argv[i], "--trusted") == 0) options.untrusted = false;
    else if (strcmp(argv[i], "--strict") == 0) options.strict = true;
    else if (strcmp(argv[i], "--primitives") == 0) options.print_primitives = true;
    else if (strcmp(argv[i], "--system") == 0) system = true;
    else if (strncmp(argv[i], "--corrupt=", 10) == 0) {
      if (sscanf(argv[i] + 10, "%d:%d", &corrupt_bci, &corrupt_value) != 2) {
        print_verify_usage();
        return 2;
      }
    }
    else if (strncmp(argv[i], "--fuzz=", 7) == 0) fuzz = atoi(argv[i] + 7);
    else if (strncmp(argv[i], "--dump=", 7) == 0) dump = atoi(argv[i] + 7);
    else if (strncmp(argv[i], "--emit-bytecodes=", 17) == 0) emit_bytecodes = argv[i] + 17;
    else if (strncmp(argv[i], "--emit-coverage=", 16) == 0) emit_coverage = argv[i] + 16;
    else if (argv[i][0] == '-') {
      print_verify_usage();
      return 2;
    } else {
      path = argv[i];
    }
  }
  if ((path == null) == !system) {
    print_verify_usage();
    return 2;
  }
  SnapshotBundle bundle = system
      ? SnapshotBundle(toit_run_snapshot, toit_run_snapshot_len)
      : SnapshotBundle::read_from_file(path);
  if (!bundle.is_valid()) {
    fprintf(stderr, "Not a valid snapshot: %s\n", system ? "<system>" : path);
    return 2;
  }
  uint8 uuid[UUID_SIZE];
  uint8* id = bundle.uuid(uuid) ? uuid : null;
  ProgramImage image = bundle.snapshot().read_image(id);
  if (!image.is_valid()) {
    fprintf(stderr, "Could not read the snapshot\n");
    return 1;
  }
  Program* program = image.program();
  // The image is read-only; give the verifier a private copy of the bytecodes
  // so that corruption experiments can patch them.
  int length = program->bytecodes.length();
  uint8* copy = unvoid_cast<uint8*>(malloc(length));
  memcpy(copy, program->bytecodes.data(), length);
  Verifier::set_bytecodes_for_testing(program, copy, length);

  if (emit_bytecodes != null) {
    // Writes the raw bytecodes so a test can locate them in the snapshot
    // file and patch them (see tests/sandbox).
    FILE* file = fopen(emit_bytecodes, "wb");
    if (file == null) { fprintf(stderr, "Could not open %s\n", emit_bytecodes); return 2; }
    size_t written = fwrite(copy, 1, length, file);
    fclose(file);
    return written == static_cast<size_t>(length) ? 0 : 2;
  }

  if (emit_coverage != null) {
    // Writes the reachability of every byte (1 = instruction start, 2 =
    // operand byte, 0 = unreached) so a test can patch only real instruction
    // operands (see tests/sandbox).
    uint8* coverage = unvoid_cast<uint8*>(calloc(length, 1));
    Verifier::set_coverage_for_testing(coverage);
    VerifierOptions quiet = options;
    quiet.verbosity = 0;
    quiet.print_primitives = false;
    VerifierStats stats;
    bool ok = Verifier::verify(program, &stats, quiet);
    Verifier::set_coverage_for_testing(null);
    if (!ok) { free(coverage); fprintf(stderr, "could not verify to compute coverage\n"); return 1; }
    FILE* file = fopen(emit_coverage, "wb");
    if (file == null) { free(coverage); fprintf(stderr, "Could not open %s\n", emit_coverage); return 2; }
    size_t written = fwrite(coverage, 1, length, file);
    fclose(file);
    free(coverage);
    return written == static_cast<size_t>(length) ? 0 : 2;
  }

  if (dump >= 0) {
    // Disassembles the method with the given id (we do not know where it
    // ends, so this stops after at most 200 instructions).
    if (dump + Method::entry_offset() > length) return 2;
    Method method(copy + dump);
    printf("method %d: arity %d, max height %d, selector offset %d, %s\n", dump, method.arity(),
           method.max_height(), method.selector_offset(),
           method.is_block_method() ? "block" : method.is_lambda_method() ? "lambda"
           : method.is_field_accessor() ? "field accessor" : "method");
    int bci = 0;
    for (int i = 0; i < 200 && dump + Method::entry_offset() + bci < length; i++) {
      uint8* bcp = method.bcp_from_bci(bci);
      int opcode = bcp[0];
      if (opcode >= ILLEGAL_END) { printf("  %5d: <invalid opcode %d>\n", static_cast<int>(bcp - copy), opcode); break; }
      printf("  %5d (+%3d): %-28s", static_cast<int>(bcp - copy), bci, opcode_name[opcode]);
      for (int j = 1; j < opcode_length[opcode]; j++) printf(" %3d", bcp[j]);
      printf("\n");
      bci += opcode_length[opcode];
    }
    return 0;
  }

  if (corrupt_bci >= 0) {
    if (corrupt_bci >= length) { fprintf(stderr, "bci out of range\n"); return 2; }
    fprintf(stderr, "corrupting byte at bci %d: %d -> %d\n", corrupt_bci, copy[corrupt_bci], corrupt_value);
    copy[corrupt_bci] = corrupt_value;
  }

  if (fuzz > 0) {
    // Mutate one random byte of the bytecodes at a time and report how
    // many mutations the verifier rejects. Deterministic seed.
    // The coverage of the unmutated program classifies accepted mutations.
    uint8* coverage = unvoid_cast<uint8*>(calloc(length, 1));
    Verifier::set_coverage_for_testing(coverage);
    VerifierOptions quiet = options;
    quiet.verbosity = 0;
    quiet.print_primitives = false;
    { VerifierStats stats;
      if (!Verifier::verify(program, &stats, quiet)) { fprintf(stderr, "fuzz: base program is rejected\n"); return 1; }
    }
    Verifier::set_coverage_for_testing(null);
    uint32 seed = 0x5eed1234;
    auto next_random = [&]() { seed = seed * 1103515245 + 12345; return (seed >> 8); };
    int rejected = 0;
    int accepted = 0;
    int accepted_unreachable = 0;
    int accepted_opcode = 0;
    int accepted_operand = 0;
    for (int i = 0; i < fuzz; i++) {
      int bci = next_random() % length;
      int value = next_random() & 0xff;
      uint8 old = copy[bci];
      if (old == value) { i--; continue; }
      copy[bci] = value;
      VerifierStats stats;
      bool ok = Verifier::verify(program, &stats, quiet);
      if (ok) {
        accepted++;
        const char* what;
        char buffer[128];
        if (coverage[bci] == 0) {
          what = "unreachable byte";
          accepted_unreachable++;
        } else if (coverage[bci] == 1) {
          snprintf(buffer, sizeof(buffer), "opcode %s -> %s", opcode_name[old],
                   value < ILLEGAL_END ? opcode_name[value] : "<invalid>");
          what = buffer;
          accepted_opcode++;
        } else {
          int start = bci;
          while (start > 0 && coverage[start] != 1) start--;
          snprintf(buffer, sizeof(buffer), "operand %d of %s", bci - start, opcode_name[copy[start]]);
          what = buffer;
          accepted_operand++;
        }
        if (options.verbosity >= 2 || accepted <= 40) {
          fprintf(stderr, "fuzz: accepted mutation bci %d: %d -> %d (%s)\n", bci, old, value, what);
        }
      } else {
        rejected++;
      }
      copy[bci] = old;
    }
    fprintf(stderr, "fuzz: %d mutations, %d rejected, %d accepted (%d unreachable bytes, %d opcodes, %d operands)\n",
            fuzz, rejected, accepted, accepted_unreachable, accepted_opcode, accepted_operand);
    free(coverage);
    return 0;
  }

  VerifierStats stats;
  bool ok = Verifier::verify(program, &stats, options);
  printf("%s methods=%d blocks=%d lambdas=%d instructions=%d bytes=%d passes=%d "
         "heap_objects=%d method_entries=%d primitive_sites=%d primitives=%d "
         "errors=%d warnings=%d time_us=%" PRId64 "\n",
         ok ? "VERIFIED" : "REJECTED",
         stats.methods, stats.blocks, stats.lambdas, stats.instructions, stats.bytes, stats.passes,
         stats.heap_objects, stats.method_entries, stats.primitive_sites, stats.distinct_primitives,
         stats.errors, stats.warnings, stats.time_us);
  return ok ? 0 : 1;
}

int main(int argc, char **argv) {
  Flags::process_args(&argc, argv);
  if (argc < 2) print_usage(1);

  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  int exit_state = 0;
  char* boot_bundle_path = null;
  if (strcmp(argv[1], "-b") == 0) {
    // The wrapping boot bundle is passed after the '-b' arg.
    if (argc < 3) {
      fprintf(stderr, "Missing argument to '-b' flag\n");
      print_usage(1);
    }
    // Malloc the path to ensure freeing works consistently.
    boot_bundle_path = unvoid_cast<char*>(malloc(strlen(argv[2]) + 1));
    strcpy(boot_bundle_path, argv[2]);
    argc -= 2;
    argv += 2;
  }

  // Verify a snapshot without running it. Used by 'toit tool verify'.
  if (strcmp(argv[1], "--verify") == 0) {
    exit(verify_snapshot(argc - 2, &argv[2]));
  }

  // Run the application as an untrusted (sandboxed) container. Equivalent
  // to -Xuntrusted.
  if (argc >= 2 && strcmp(argv[1], "--untrusted") == 0) {
    Flags::untrusted = true;
    argc -= 1;
    argv += 1;
    if (argc < 2) print_usage(1);
  }

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

  // TODO(2663): remove support for '-r'.
  if (strcmp(argv[1], "-r") == 0 ||
      SnapshotBundle::is_bundle_file(argv[1])) {
    // Bundle reading.
    bool with_flag = strcmp(argv[1], "-r") == 0;
    if (with_flag && argc < 3) {
      fprintf(stderr, "Missing argument to '-r' flag\n");
      print_usage(1);
    }
    int bundle_argv_index = with_flag ? 2 : 1;
    Flags::program_name = argv[bundle_argv_index];
    Flags::program_path = OS::get_executable_path_from_arg(argv[bundle_argv_index]);
    char* bundle_file = argv[bundle_argv_index];
    auto bundle = SnapshotBundle::read_from_file(bundle_file);
    if (!bundle.is_valid()) print_usage(1);
    exit_state = run_program(boot_bundle_path, bundle, &argv[bundle_argv_index + 1]);
    // The bundle is put in an external ByteArray and automatically freed when
    // the heap is torn down.
    // TODO(florian): it looks like we don't free the bundle. There is a copy
    //   of the bundle in the byte-array (which is automatically freed), but the
    //   initial memory isn't released.
  } else {
    char* bundle_filename = null;

    int source_path_count = 0;
    const char* source_path = null;
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
    int optimization_level = DEFAULT_OPTIMIZATION_LEVEL;

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
      if (strcmp(argv[processed_args], "-O0") == 0) {
        optimization_level = 0;
        processed_args++;
      } else if (strcmp(argv[processed_args], "-O1") == 0) {
        optimization_level = 1;
        processed_args++;
      } else if (strcmp(argv[processed_args], "-O2") == 0) {
        optimization_level = 2;
        processed_args++;
      } else if (strcmp(argv[processed_args], "-w") == 0) {
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
      } else if (strcmp(argv[processed_args], "-s") == 0) {
        processed_args++;
        ways_to_run++;
        if (processed_args == argc) {
          fprintf(stderr, "Missing argument to '-s'\n");
          print_usage(1);
        }
        if (direct_script != null) {
          fprintf(stderr, "Only one '-s' flag is allowed.\n");
          print_usage(1);
        }
        direct_script = argv[processed_args++];
      } else if (strncmp(argv[processed_args], "-s", 2) == 0) {
        ways_to_run++;
        if (direct_script != null) {
          fprintf(stderr, "Only one '-s' flag is allowed.\n");
          print_usage(1);
        }
        direct_script = &argv[processed_args++][2];
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
          if (is_binary_file(source_path) && !SnapshotBundle::is_bundle_file(source_path)) {
            fprintf(stderr, "Not a text-only source file or a snapshot: %s\n", source_path);
            print_usage(1);
          }
          source_path_count = 1;
        }
        break;
      }
    }

    Flags::program_name = source_path;
    Flags::program_path = source_path == null
        ? null
        : OS::get_executable_path_from_arg(source_path);

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
    if (dep_format == compiler::Compiler::DepFormat::ninja && bundle_filename == null) {
      fprintf(stderr, "Ninja dependency-format can only be used when compiling a snapshot\n");
      print_usage(1);
    }

    if (for_language_server && dep_file != null) {
      fprintf(stderr, "Can't generate dependency file with --lsp\n");
      print_usage(1);
    }

    bool generating_bundle = bundle_filename != null;

    compiler::Compiler::Configuration compiler_config = {
      .dep_file = dep_file,
      .dep_format = dep_format,
      .project_root = project_root,
      .force = force,
      .werror = werror,
      .show_package_warnings = show_package_warnings,
      // Unless we are running the program, we want the diagnostics on stdout.
      // The compiler might ignore this setting for some configurations, like when
      // running the language-server, in which case the diagnostics must be on stdout.
      .print_diagnostics_on_stdout = for_analysis || generating_bundle,
      .optimization_level = optimization_level,
      .verbosity = 0,
    };

    if (for_language_server) {
      compiler::Compiler compiler;
      compiler.language_server(compiler_config);
    } else if (for_analysis) {
      compiler::Compiler compiler;
      compiler.analyze(List<const char*>(source_paths, source_path_count),
                       compiler_config,
                       false);  // Not for dependencies.
    } else {
      auto compiled = SnapshotBundle::invalid();
      { compiler::Compiler compiler;  // Scope the compiler, so we destroy it before running the interpreter.
        auto source_path = source_path_count == 0 ? null : source_paths[0];
        compiled = compiler.compile(source_path,
                                    direct_script,
                                    bundle_filename,
                                    compiler_config);
      }
      if (!generating_bundle) {
        exit_state = run_program(boot_bundle_path,
                                 compiled,
                                 args);
      } else {
        if (!compiled.write_to_file(bundle_filename)) {
          print_usage(1);
        }
        free(compiled.buffer());
      }
    }
  }

  free(boot_bundle_path);

  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_state;
}

} // namespace toit

int main(int argc, char** argv) {
  return run_with_utf_8_args(toit::main, argc, argv);
}

// Copyright (C) 2023 Toitware ApS.
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

#include "top.h"

namespace toit {

#define FLAG_BOOL(macro, name, value, doc) macro(bool, bool, name, value, doc)
#define FLAG_INT(macro, name, value, doc)  macro(int, int, name, value, doc)
#define FLAG_STRING(macro, name, value, doc) macro(const char*, string, name, value, doc)

#ifdef TOIT_DEBUG
#define _ASSERT_DEFAULT true
#else
#define _ASSERT_DEFAULT false
#endif

#ifdef TOIT_WINDOWS
#define _NO_FORK true
#else
#define _NO_FORK false
#endif

#ifdef TOIT_FREERTOS
#define TRACE_GC false
#else
#define TRACE_GC false
#endif

#define FLAGS_DO(debug, deploy)                                                     \
  FLAG_BOOL(deploy,  bool_deploy,        false, "Test bool deploy flag")            \
  FLAG_INT(deploy,   int_deploy,             0, "Test int deploy flag")             \
  FLAG_INT(debug,    int_debug,         0xcafe, "Test int debug flag")              \
                                                                                    \
  /* Default for LWIP-on-Linux test config is to use a static IP. */                \
  FLAG_BOOL(deploy,  dhcp,                  false, "Use DHCP (only LWIP-on-Linux")  \
  FLAG_BOOL(deploy,  no_fork,               _NO_FORK, "Don't fork the compiler")    \
  FLAG_BOOL(deploy,  propagate,             false, "Propagate types")               \
  FLAG_BOOL(deploy,  verify,                false, "Verify programs when they are loaded") \
  FLAG_BOOL(debug,   trace,                 false, "Trace interpreter")             \
  FLAG_BOOL(debug,   primitives,            false, "Trace primitives")              \
  FLAG_BOOL(deploy,  tracegc,               TRACE_GC, "Trace garbage collector")    \
  FLAG_BOOL(debug,   validate_heap,         false, "Check garbage collector")       \
  FLAG_BOOL(debug,   gc_a_lot,              false, "Garbage collect after each allocation in the interpreter") \
  FLAG_BOOL(debug,   preempt_a_lot,         false, "Preempt process after each pop bytecode") \
  FLAG_BOOL(debug,   shrink_stacks_a_lot,   false, "Shrink stacks on every GC")     \
  FLAG_BOOL(debug,   lookup,                false, "Trace lookup")                  \
  FLAG_BOOL(debug,   allocation,            false, "Trace object allocation")       \
  FLAG_BOOL(debug,   print_nodes,           false, "Print AST nodes")               \
  FLAG_BOOL(debug,   verbose,               false, "Mooore debug output")           \
  FLAG_BOOL(debug,   compiler,              false, "Trace compilation process")     \
  FLAG_BOOL(debug,   print_ir_tree,         false, "Print the IR tree")             \
  FLAG_BOOL(debug,   print_dispatch_table,  false, "Print the dispatch table")      \
  FLAG_BOOL(debug,   print_bytecodes,       false, "Print the bytecodes for each method") \
  FLAG_BOOL(debug,   disable_tree_shaking,  false, "Disables tree-shaking")         \
  FLAG_BOOL(debug,   report_tree_shaking,   false, "Report stats on tree shaking")  \
  FLAG_BOOL(debug,   print_dependency_tree, false, "Prints the dependency tree used in the source-shaking") \
  FLAG_BOOL(deploy,  enable_asserts,        _ASSERT_DEFAULT, "Enables asserts")     \
  FLAG_BOOL(deploy,  migrate_dash_ids,      false, "Prints migration information for dash identifiers")  \
  FLAG_INT(deploy,   max_recursion_depth,   2000,  "Max recursion depth in the parser") \
  FLAG_INT(deploy,   bytecode_format,       0,     "Bytecode format the compiler generates (1 or 2; 0: TOIT_BYTECODE_FORMAT, else the build's default, see docs/format2-migration.md)") \
  FLAG_BOOL(deploy,  certificate,           true,  "Format 2: ship a certificate with snapshots compiled with --untrusted (toit.run --certify)") \
  FLAG_INT(deploy,   v2_builtins,           7,     "Format 2, proposal (format note 19): built-ins to emit, bit 0 LOOP_REPEAT, 1 LOOP_ARRAY, 2 HASH_FIND (also TOIT_V2_BUILTINS)") \
  FLAG_BOOL(deploy,  v2_unchecked,          true,  "Format 2: emit the trusted-only unchecked twins of the field accesses (format note 20; also TOIT_V2_UNCHECKED); never with --untrusted") \
  FLAG_STRING(deploy, lib_path,             null,  "The library path")              \
  FLAG_STRING(deploy, archive_entry_path,   null,  "The entry path in an archive")  \
  FLAG_STRING(deploy, sandbox,              null,  "syscall-sandbox: compiler or sandbox")  \
  FLAG_STRING(deploy, compiler_sandbox,     null,  "syscall-sandbox for the forked compiler: compiler or sandbox")  \
  FLAG_BOOL(deploy,  untrusted,             false, "Compile for (and, in toit.run, run as) an untrusted (sandboxed) container: format 2, checked opcodes only") \
  FLAG_INT(deploy,   sandbox_heap_floor,    0,     "Bytes of the system heap that messages and starts of sandboxed processes must leave free (0: none; host: of the simulated system heap -Xsandbox_system_heap)") \
  FLAG_INT(deploy,   sandbox_growth_headroom, 16384, "Bytes above the sandbox heap floor that the heap growth of sandboxed processes leaves free") \
  FLAG_INT(deploy,   sandbox_system_heap,   0,     "Host: the size of the system heap the sandbox heap floor is simulated with (it holds the heaps of the sandboxed processes and their messages)") \
  FLAG_INT(deploy,   sandbox_start_bytes,   16384, "Bytes above the sandbox heap floor and growth headroom that must be free to start a sandboxed process (with -Xsandbox_heap_floor)") \
  FLAG_BOOL(deploy,  require_certificate,   false, "Verify format-2 programs only with a shipped certificate, as devices do (also TOIT_REQUIRE_CERTIFICATE=1)") \
  FLAG_STRING(deploy, inject_system_oom,     null,  "Test: SITE:N, the next N allocation attempts at SITE (spawn, commit, header-page, reserve) fail in the system process (src/out_of_memory.h)") \

#ifdef TOIT_DEBUG
#define DECLARE_DEBUG_FLAG(type, prefix, name, value, doc) static type name;
#else
#define DECLARE_DEBUG_FLAG(type, prefix, name, value, doc) static constexpr type name = value;
#endif

#ifndef TOIT_FREERTOS
#define DECLARE_DEPLOY_FLAG(type, prefix, name, value, doc) static type name;
#else
#define DECLARE_DEPLOY_FLAG(type, prefix, name, value, doc) static constexpr type name = value;
#endif

class Flags {
 public:
  FLAGS_DO(DECLARE_DEBUG_FLAG, DECLARE_DEPLOY_FLAG)

  static const char* program_name;
  static const char* program_path;

#ifndef TOIT_FREERTOS
  static int process_args(int* argc, char** argv);
#endif
};

} // namespace toit

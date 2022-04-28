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

#include "top.h"

namespace toit {

#define FLAG_BOOL(macro, name, value, doc) macro(bool, bool, name, value, doc)
#define FLAG_INT(macro, name, value, doc)  macro(int, int, name, value, doc)
#define FLAG_STRING(macro, name, value, doc) macro(const char*, string, name, value, doc)

#ifdef DEBUG
#define _ASSERT_DEFAULT true
#else
#define _ASSERT_DEFAULT false
#endif

#ifdef TOIT_WINDOWS
#define _NO_FORK true
#else
#define _NO_FORK false
#endif

#define FLAGS_DO(debug, deploy)                                                     \
  FLAG_BOOL(deploy,  bool_deploy,        false, "Test bool deploy flag")            \
  FLAG_INT(deploy,   int_deploy,             0, "Test int deploy flag")             \
  FLAG_INT(debug,    int_debug,         0xcafe, "Test int debug flag")              \
                                                                                    \
  /* Default for LWIP-on-Linux test config is to use a static IP */                 \
  FLAG_BOOL(deploy,  dhcp,                  false, "Use DHCP (only LWIP-on-Linux")  \
  FLAG_BOOL(deploy,  no_fork,               _NO_FORK, "Don't fork the compiler")    \
  FLAG_BOOL(debug,   trace,                 false, "Trace interpreter")             \
  FLAG_BOOL(debug,   primitives,            false, "Trace primitives")              \
  FLAG_BOOL(deploy,  tracegc,               false, "Trace garbage collector")       \
  FLAG_BOOL(debug,   validate_heap,         true, "Check garbage collector")       \
  FLAG_BOOL(debug,   gcalot,                false, "Garbage collect after each allocation in the interpreter") \
  FLAG_BOOL(debug,   preemptalot,           false, "Preempt process after each pop bytecode") \
  FLAG_BOOL(debug,   lookup,                false, "Trace lookup")                  \
  FLAG_BOOL(debug,   allocation,            false, "Trace object allocation")       \
  FLAG_BOOL(debug,   cheap,                 false, "Trace malloc and free")         \
  FLAG_BOOL(debug,   print_nodes,           false, "Print AST nodes")               \
  FLAG_BOOL(debug,   verbose,               false, "Mooore debug output")           \
  FLAG_BOOL(debug,   compiler,              false, "Trace compilation process")     \
  FLAG_BOOL(debug,   print_ir_tree,         false, "Print the IR tree")             \
  FLAG_BOOL(debug,   print_dispatch_table,  false, "Print the dispatch table")      \
  FLAG_BOOL(debug,   print_bytecodes,       false, "Print the bytecodes for each method") \
  FLAG_BOOL(debug,   disable_tree_shaking,  false, "Disables tree-shaking")         \
  FLAG_BOOL(debug,   report_tree_shaking,   false, "Report stats on tree shaking")  \
  FLAG_BOOL(debug,   print_dependency_tree, false, "Prints the dependency tree used in the source-shaking")               \
  FLAG_BOOL(deploy,  enable_asserts,        _ASSERT_DEFAULT, "Enables asserts")     \
  FLAG_INT(deploy,   max_recursion_depth,   2000,  "Max recursion depth in the parser") \
  FLAG_STRING(deploy, lib_path,             null,  "The library path")              \
  FLAG_STRING(deploy, archive_entry_path,   null,  "The entry path in an archive")  \
  FLAG_STRING(deploy, sandbox,              null,  "syscall-sandbox: compiler or sandbox")  \
  FLAG_STRING(deploy, compiler_sandbox,     null,  "syscall-sandbox for the forked compiler: compiler or sandbox")  \

#ifdef DEBUG
#define DECLARE_DEBUG_FLAG(type, prefix, name, value, doc) static type name;
#else
#define DECLARE_DEBUG_FLAG(type, prefix, name, value, doc) static const type name = value;
#endif

#define DECLARE_DEPLOY_FLAG(type, prefix, name, value, doc) static type name;

class Flags {
 public:
  FLAGS_DO(DECLARE_DEBUG_FLAG, DECLARE_DEPLOY_FLAG)

#ifndef IOT_DEVICE
  static int process_args(int* argc, char** argv);
#endif
};

} // namespace toit

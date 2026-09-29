// Copyright (C) 2026 Toit contributors.
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

#include "dispatch_table.h"
#include "ir.h"

namespace toit {
namespace compiler {

/// Compiles an (optimized and tree-shaken) IR program to a WebAssembly
/// module that uses the WebAssembly GC for all Toit objects.
///
/// This is a prototype. The module is emitted in the WebAssembly text format
/// (WAT) and must be assembled with Binaryen's 'wasm-as'. See
/// docs/wasm-gc-backend.md for the design.
class WasmBackend {
 public:
  WasmBackend(ir::Program* program, DispatchTable* dispatch_table)
      : program_(program), dispatch_table_(dispatch_table) {}

  /// Returns the module in the WebAssembly text format.
  std::string emit();

 private:
  ir::Program* program_;
  DispatchTable* dispatch_table_;
};

} // namespace toit::compiler
} // namespace toit

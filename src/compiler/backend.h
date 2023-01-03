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

#include "byte_gen.h"
#include "ir.h"
#include "sources.h"

namespace toit {
namespace compiler {

class DispatchTable;
class Parser;
class ProgramBuilder;
class Diagnostics;
class SourceMapper;
class SymbolCanonicalizer;

class Backend {
 public:
  explicit Backend(SourceManager* source_manager, SourceMapper* source_mapper)
      : source_manager_(source_manager)
      , source_mapper_(source_mapper) {}

  // As a side-effect fills in the source-mapper.
  Program* emit(ir::Program* program);

 private:
  SourceManager* source_manager_;
  SourceMapper* source_mapper_;

  SourceMapper* source_mapper() { return source_mapper_; }
  void assign_global_ids(List<ir::Global*> globals);
  void assign_field_indexes(List<ir::Class*> classes);
  void emit_method(ir::Method* method,
                   ByteGen* gen,
                   UnorderedMap<ir::Class*, int>* typecheck_indexes,
                   DispatchTable* dispatch_table,
                   ProgramBuilder* program_builder);
  void emit_global(ir::Global* globals,
                   ByteGen* gen,
                   ProgramBuilder* program_builder);
  void emit_class(ir::Class* klass,
                  const DispatchTable* dispatch_table,
                  SourceMapper* source_mapper,
                  ProgramBuilder* program_builder);
};

} // namespace toit::compiler
} // namespace toit

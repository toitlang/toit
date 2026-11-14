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

#include "top.h"

namespace toit {

class Program;

// The set of legal method entries (method ids) of a program.
//
// The interpreter turns integers that it reads from the stack or from heap
// objects into code addresses: block method ids in method-id slots,
// `Lambda_.method_`, `LazyInitializer_` ids and the entry of `spawn`. A
// malformed or malicious program can put any integer there, which would
// start execution at an arbitrary byte offset. Every such id is checked
// against this table before the interpreter constructs a `Method` from it.
//
// The table is computed when a program is loaded, by decoding all code that
// is reachable from the dispatch table and the lazy global initializers,
// following branches and the method ids of LOAD_METHOD. It is a bitmap with
// one bit per byte of the bytecodes.
class MethodEntryTable {
 public:
  ~MethodEntryTable();

  // Computes the table for the given program. Returns null if the
  // allocation fails.
  static MethodEntryTable* compute(Program* program);

  // Whether the given id is the start of a method header.
  bool is_entry(word id) const {
    uword index = static_cast<uword>(id);
    if (index >= length_) return false;
    return ((bits_[index >> 3] >> (index & 7)) & 1) != 0;
  }

  // The number of entries in the table.
  word count() const { return count_; }

 private:
  MethodEntryTable(uint8* bits, uword length) : bits_(bits), length_(length) {}

  uint8* const bits_;
  const uword length_;
  word count_ = 0;
};

} // namespace toit

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

#include "../entry_points.h"

namespace toit {
namespace compiler {

// Pairs of program-name and their symbol.
// The first parameter is the name in the Program class: `X_class`.
// The second parameter is the symbol name for the class: `Symbols::Y`.
#define TREE_ROOT_CLASSES(T)            \
  T(array, SmallArray_)                 \
  T(byte_array, ByteArray_)             \
  T(byte_array_cow, CowByteArray_)      \
  T(byte_array_slice, ByteArraySlice_)  \
  T(list, List_)                        \
  T(tombstone, Tombstone_)              \
  T(map, Map)                           \
  T(string, String_)                    \
  T(string_slice, StringSlice_)         \
  T(double, float_)                     \
  T(large_integer, LargeInteger_)       \
  T(false, False_)                      \
  T(null, Null_)                        \
  T(object, Object)                     \
  T(smi, SmallInteger_)                 \
  T(task, Task_)                        \
  T(large_array, LargeArray_)           \
  T(true, True_)                        \
  T(lazy_initializer, LazyInitializer_) \
  T(stack, Stack_)                      \
  T(exception, Exception_)              \

} // namespace toit::compiler
} // namespace toit

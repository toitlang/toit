// Copyright (C) 2022 Toitware ApS.
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

#include "type_set.h"
#include "../../primitive.h"

namespace toit {

class Program;

namespace compiler {

#define TYPE_PRIMITIVE(name) \
  static void type_primitive_##name(Program* program, TypeSet result, TypeSet failure)

#define TYPE_PRIMITIVE_HELPER(name, method) \
  TYPE_PRIMITIVE(name) {         \
    result.method(program);      \
    failure.add_string(program); \
  }

#define TYPE_PRIMITIVE_ANY(name)        TYPE_PRIMITIVE_HELPER(name, add_any)
#define TYPE_PRIMITIVE_ARRAY(name)      TYPE_PRIMITIVE_HELPER(name, add_array)
#define TYPE_PRIMITIVE_SMI(name)        TYPE_PRIMITIVE_HELPER(name, add_smi)
#define TYPE_PRIMITIVE_INT(name)        TYPE_PRIMITIVE_HELPER(name, add_int)
#define TYPE_PRIMITIVE_BOOL(name)       TYPE_PRIMITIVE_HELPER(name, add_bool)
#define TYPE_PRIMITIVE_NULL(name)       TYPE_PRIMITIVE_HELPER(name, add_null)
#define TYPE_PRIMITIVE_TASK(name)       TYPE_PRIMITIVE_HELPER(name, add_task)
#define TYPE_PRIMITIVE_FLOAT(name)      TYPE_PRIMITIVE_HELPER(name, add_float)
#define TYPE_PRIMITIVE_STRING(name)     TYPE_PRIMITIVE_HELPER(name, add_string)
#define TYPE_PRIMITIVE_BYTE_ARRAY(name) TYPE_PRIMITIVE_HELPER(name, add_byte_array)

// ----------------------------------------------------------------------------

struct TypePrimitiveEntry {
  void* function;
  int arity;
};

class TypePrimitive {
 public:
  typedef void Entry(Program* program, TypeSet result, TypeSet failure);
  static void set_up();

  // Module-specific primitive lookup. May return null if the primitive isn't linked in.
  static const TypePrimitiveEntry* at(unsigned module, unsigned index) {
    const TypePrimitiveEntry* table = primitives_[module];
    return (table == null) ? null : &table[index];
  }

 private:
  static const TypePrimitiveEntry* primitives_[];
};

// ----------------------------------------------------------------------------

#define MODULE_TYPE_PRIMITIVE(name, arity)                          \
  TYPE_PRIMITIVE(name);
#define MODULE_TYPE_PRIMITIVE_ENTRY(name, arity)                    \
  { (void*) type_primitive_##name, arity },
#define MODULE_TYPES(name, entries)                                 \
  entries(MODULE_TYPE_PRIMITIVE)                                    \
  static const TypePrimitiveEntry name##_type_table[] = {           \
    entries(MODULE_TYPE_PRIMITIVE_ENTRY)                            \
  };                                                                \
  const TypePrimitiveEntry* name##_types_ = name##_type_table;

}  // namespace toit::compiler
}  // namespace toit
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

#include "resolver_primitive.h"
#include "../primitive.h"

namespace toit {
namespace compiler{

#define PRIMITIVE_NAME(name, arity) \
  #name,
#define PRIMITIVE_NAME_TABLE(name, entries) \
static const char* name##names_[] = { \
  entries(PRIMITIVE_NAME) \
  null \
};
MODULES(PRIMITIVE_NAME_TABLE)

#define PRIMITIVE_ARITY(name, arity) \
  arity,
#define PRIMITIVE_ARITY_TABLE(name, entries) \
static int name##_arities[] = { \
  entries(PRIMITIVE_ARITY) \
};
MODULES(PRIMITIVE_ARITY_TABLE)

#define MODULE_NAME(name, entries) \
  #name,
#define MODULE_PRIMITIVE_NAMES(name, entries) \
  name##names_,
#define MODULE_PRIMITIVE_ARITIES(name, entries) \
  name##_arities,
static const char* module_names[] = {
  MODULES(MODULE_NAME)
};
static const char** module_primitive_names[] = {
  MODULES(MODULE_PRIMITIVE_NAMES)
};
static int* module_primitive_arities[] = {
  MODULES(MODULE_PRIMITIVE_ARITIES)
};

#undef PRIMITIVE_NAME
#undef PRIMITIVE_NAME_TABLE
#undef MODULE_NAME
#undef MODULE_PRIMITIVE_NAMES
#undef MODULE_PRIMITIVE_ARITIES

int PrimitiveResolver::find_module(compiler::Symbol name) {
  for (unsigned i = 0; i < ARRAY_SIZE(module_names); i++) {
    if (strcmp(name.c_str(), module_names[i]) == 0) return i;
  }
  return -1;
}

int PrimitiveResolver::find_primitive(compiler::Symbol name, int module) {
  ASSERT(module >= 0 && module < static_cast<int>(ARRAY_SIZE(module_names)));
  const char** names = module_primitive_names[module];
  for (int i = 0; names[i] != null; i++) {
    if (strcmp(names[i], name.c_str()) == 0) return i;
  }
  return -1;
}

int PrimitiveResolver::arity(int primitive, int module) {
  ASSERT(primitive >= 0);
  ASSERT(0 <= module && module < static_cast<int>(ARRAY_SIZE(module_names)));
  int* arities = module_primitive_arities[module];
  return arities[primitive];
}

int PrimitiveResolver::number_of_modules() {
  return ARRAY_SIZE(module_names);
}

const char* PrimitiveResolver::module_name(int index) {
  ASSERT(index >= 0 && index < number_of_modules());
  return module_names[index];
}

int PrimitiveResolver::number_of_primitives(int module) {
  ASSERT(module >= 0 && module < number_of_modules());
  const char** names = module_primitive_names[module];
  int size = 0;
  while (*names++ != null) size++;
  return size;
}

const char* PrimitiveResolver::primitive_name(int module, int index) {
  ASSERT(module >= 0 && module < number_of_modules());
  const char** names = module_primitive_names[module];
  return names[index];
}

} // namespace compiler
} // namespace toit

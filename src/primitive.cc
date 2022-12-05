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

#include "primitive.h"
#include "process.h"
#include "objects_inline.h"

#ifdef TOIT_FREERTOS
#include "esp_err.h"
#endif

namespace toit {

#define MODULE_ENUM(name, entries) INDEX_##name,
enum {
  MODULES(MODULE_ENUM)
  COUNT
};
#undef MODULE_ENUM

#define MODULE_PRIMITIVES_WEAK(name, entries) \
  const PrimitiveEntry* name##_primitives_ __attribute__((weak)) = null;
#define MODULE_PRIMITIVES(name, entries) \
  primitives_[INDEX_##name] = name##_primitives_;

const PrimitiveEntry* Primitive::primitives_[COUNT];

MODULES(MODULE_PRIMITIVES_WEAK)
void Primitive::set_up() {
  MODULES(MODULE_PRIMITIVES)
}

#undef MODULE_PRIMITIVES_WEAK
#undef MODULE_PRIMITIVES

// ----------------------------------------------------------------------------

Object* Primitive::allocate_double(double value, Process* process) {
  Object* result = process->object_heap()->allocate_double(value);
  if (result != null) return result;
  return mark_as_error(process->program()->allocation_failed());
}

Object* Primitive::allocate_large_integer(int64 value, Process* process) {
  Object* result = process->object_heap()->allocate_large_integer(value);
  if (result != null) return result;
  return mark_as_error(process->program()->allocation_failed());
}

Object* Primitive::allocate_array(int length, Object* filler, Process* process) {
  ASSERT(length <= Array::max_length_in_process());
  if (length > Array::max_length_in_process()) return null;
  Object* result = length == 0 ? process->program()->empty_array() :process->object_heap()->allocate_array(length, filler);
  if (result != null) return result;
  return mark_as_error(process->program()->allocation_failed());
}

Object* Primitive::os_error(int error, Process* process) {
#ifdef TOIT_FREERTOS
  if (error == ESP_ERR_NO_MEM) MALLOC_FAILED;
  const size_t BUF_SIZE = 200;
  char buffer[BUF_SIZE];
  // This makes a string that is either informative or of the form: "UNKNOWN
  // ERROR 0x2a(42)"
  esp_err_to_name_r(error, buffer, BUF_SIZE);
  buffer[BUF_SIZE - 1] = '\0';
  char* error_text = buffer;
#else
  char* error_text = strerror(error);
#endif
  String* result = process->allocate_string(error_text);
  if (result == null) ALLOCATION_FAILED;
  return Error::from(result);
}

}  // namespace toit

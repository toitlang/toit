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

#include <string.h>

#include "primitive.h"
#include "process.h"
#include "objects_inline.h"

#ifdef TOIT_ESP32
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

Object* Primitive::allocate_array(word length, Object* filler, Process* process) {
  ASSERT(length <= Array::max_length_in_process());
  if (length > Array::max_length_in_process()) return null;
  Object* result = length == 0 ? process->program()->empty_array() :process->object_heap()->allocate_array(length, filler);
  if (result != null) return result;
  return mark_as_error(process->program()->allocation_failed());
}

Object* Primitive::os_error(int error, Process* process, const char* operation) {
#ifdef TOIT_ESP32
  if (error == ESP_ERR_NO_MEM) FAIL(MALLOC_FAILED);
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
  if (operation != null) {
    const char* format = "Failed to %s: %s";
    auto length = strlen(format) + strlen(operation) + strlen(error_text) + 1;
    char* message = static_cast<char*>(malloc(length));
    if (message == null) FAIL(MALLOC_FAILED);
    snprintf(message, length, format, operation, error_text);
    error_text = message;
  }
  String* result = process->allocate_string(error_text);
  if (result == null) FAIL(ALLOCATION_FAILED);
  return Error::from(result);
}

Object* Primitive::return_not_a_smi(Process* process, Object* value) {
  if (is_large_integer(value)) {
    FAIL(OUT_OF_RANGE);
  } else {
    FAIL(WRONG_OBJECT_TYPE);
  }
}

Object* Primitive::unmark_from_error(Program* program, Object* marked_error) {
  ASSERT((reinterpret_cast<uword>(marked_error) & 3) == Error::ERROR_TAG);
  if (reinterpret_cast<uword>(marked_error) < Error::MAX_TAGGED_ERROR) {
    return program->root(reinterpret_cast<uword>(marked_error) >> Error::ERROR_SHIFT);
  }
  return marked_error->unmark();
}

}  // namespace toit

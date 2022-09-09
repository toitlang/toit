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
  const PrimitiveEntry* name##_primitives __attribute__((weak));
#define MODULE_PRIMITIVES(name, entries) \
  _primitives[INDEX_##name] = name##_primitives;

const PrimitiveEntry* Primitive::_primitives[COUNT];

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
  Object* result = length == 0 ? process->program()->empty_array() :process->object_heap()->allocate_array(length, filler);
  if (result != null) return result;
  return mark_as_error(process->program()->allocation_failed());
}

Object* Primitive::os_error(int error, Process* process) {
#ifdef TOIT_FREERTOS
  if (error == ESP_ERR_NO_MEM) MALLOC_FAILED;
#endif
  Error* err = null;
  String* result = process->allocate_string(strerror(error), &err);
  if (result == null) return err;
  return Error::from(result);
}

void Primitive::get_primitive_name(const char** module_return, const char** primitive_return, int module_number, int primitive_number) {
  switch (module_number) {
    case 0:
      *module_return = "Core";
      return;
    case 1:
      *module_return = "Timer";
      return;
    case 2:
      *module_return = "TCP";
      switch (primitive_number) {
        case 7:
          *primitive_return = "read";
      }
      return;
    case 3:
      *module_return = "UDP";
      return;
    case 4:
      *module_return = "TLS";
      switch (primitive_number) {
        case 2:
          *primitive_return = "init_socket";
        case 8:
          *primitive_return = "handshake";
        case 15:
          *primitive_return = "error";
      }
      return;
  }
}

}  // namespace toit

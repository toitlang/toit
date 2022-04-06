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

#include "visitor.h"
#include "objects.h"

#include "objects_inline.h"

namespace toit {

void Visitor::accept(Object* object) {
  if (object->is_smi()) {
    visit_smi(Smi::cast(object));
    return;
  }
  HeapObject* heap_object = HeapObject::cast(object);
  switch (heap_object->class_tag()) {
    case TypeTag::ARRAY_TAG:
      visit_array(Array::cast(heap_object));
      break;
    case TypeTag::BYTE_ARRAY_TAG:
      visit_byte_array(ByteArray::cast(heap_object));
      break;
    case TypeTag::STACK_TAG:
      visit_stack(Stack::cast(heap_object));
      break;
    case TypeTag::STRING_TAG:
      visit_string(String::cast(heap_object));
      break;
    case TypeTag::INSTANCE_TAG:
      visit_instance(Instance::cast(heap_object));
      break;
    case TypeTag::ODDBALL_TAG:
      visit_oddball(HeapObject::cast(heap_object));
      break;
    case TypeTag::DOUBLE_TAG:
      visit_double(Double::cast(heap_object));
      break;
    case TypeTag::LARGE_INTEGER_TAG:
      visit_large_integer(LargeInteger::cast(heap_object));
      break;
    case TypeTag::TASK_TAG:
      visit_task(Task::cast(heap_object));
      break;
  default:
    FATAL("Unexpected class tag");
  }
}

}

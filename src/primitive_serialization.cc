// Copyright (C) 2020 Toitware ApS.
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

#include "top.h"

#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "snapshot.h"

namespace toit {

MODULE_IMPLEMENTATION(serialization, MODULE_SERIALIZATION)

PRIMITIVE(serialize) {
#ifdef TOIT_FREERTOS
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(Object, object);
  ByteArray* result = process->object_heap()->allocate_proxy();
  if (result == null) ALLOCATION_FAILED;
  SnapshotGenerator generator(process->program());
  generator.generate(object, process);
  int length;
  uint8* buffer = generator.take_buffer(&length);
  if (buffer == null) MALLOC_FAILED;
  result->set_external_address(length, buffer);
  return result;
#endif
}

PRIMITIVE(deserialize) {
#ifdef TOIT_FREERTOS
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(Blob, bytes);
  Snapshot snapshot(bytes.address(), bytes.length());
  auto result = snapshot.read_object(process);
  if (result == null) ALLOCATION_FAILED;
  return result;
#endif
}

} // namespace toit

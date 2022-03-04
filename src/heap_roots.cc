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

#include "flags.h"
#include "heap_roots.h"
#include "objects.h"
#include "process.h"

#include "objects_inline.h"

namespace toit {

void FinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&_key));
  cb->do_root(reinterpret_cast<Object**>(&_lambda));
}

void VMFinalizerNode::roots_do(RootCallback* cb) {
  cb->do_root(reinterpret_cast<Object**>(&_key));
}

void VMFinalizerNode::free_external_memory(Process* process) {
  uint8* memory = null;
  word accounting_size = 0;
  if (key()->is_byte_array()) {
    ByteArray* byte_array = ByteArray::cast(key());
    if (byte_array->external_tag() == MappedFileTag) return;  // TODO(erik): release mapped file, so flash storage can be reclaimed.
    ASSERT(byte_array->has_external_address());
    ByteArray::Bytes bytes(byte_array);
    memory = bytes.address();
    accounting_size = bytes.length();
    // Accounting size is 0 if the byte array is tagged, since we don't account
    // memory for Resources etc.
    ASSERT(byte_array->external_tag() == RawByteTag || byte_array->external_tag() == NullStructTag);
  } else if (key()->is_string()) {
    String* string = String::cast(key());
    memory = string->as_external();
    // Add one because the strings are allocated with a null termination byte.
    accounting_size = string->length() + 1;
  }
  if (memory != null) {
    if (Flags::allocation) printf("Deleting external memory for string %p\n", memory);
    free(memory);
    process->unregister_external_allocation(accounting_size);
  }
}

}  // namespace.

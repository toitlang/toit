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

// Pilot target (d): PRIMITIVE(string_write_to_byte_array) of
// src/primitive_core.cc, a copy between two blobs that may overlap: the
// destination can be the source byte array itself or a byte-array slice of
// it (af4ba7ab replaced a memcpy by memmove here).
//
// The real primitive body with its ARGS(Blob, MutableBlob, word, word,
// word) decoding is compiled unmodified (src/primitive_core.cc,
// Object::byte_content of src/objects.cc); Object::mutable_byte_content is
// extracted verbatim from src/objects_runtime.cc by esbmc.sh (tool defect
// T3). Modelled: Process::allocate_byte_array (src/process.cc: null or a
// fresh zeroed byte array; reached through copy-on-write arrays) and the
// card-marking write barrier.
//
// Properties, for every source (string or byte array, internal or
// external, up to CXXV_BLOB bytes), every destination (the source itself,
// a slice of it with arbitrary bounds, or another byte array) and every
// from, to, dest_index:
//  P1 no out-of-bounds access, no invalid pointer, no signed overflow;
//  P2 on success, destination byte dest_index + k is the source byte
//     from + k as it was before the call, for every k < to - from (memmove
//     semantics), checked for one arbitrary k.

#define RAW
#define private public
#define protected public
#include "prelude.h"
#include "third_party/dartino/gc_metadata.h"
namespace toit {
template <> inline void GcMetadata::insert_into_remembered_set<Instance*>(Instance* address) {}
template <> inline void GcMetadata::insert_into_remembered_set<Array*>(Array* address) {}
template <> inline void GcMetadata::insert_into_remembered_set<Stack*>(Stack* address) {}
}  // namespace toit
#include "primitive_core.cc"
#include "objects.cc"
namespace toit {
#include "mbc4.inc"
#include "mbc5.inc"
#include "mbc_blob.inc"
}  // namespace toit
#undef private
#undef protected

#include "constants.h"
#include "heap_model.h"

using namespace toit;

#ifndef CXXV_BLOB_MAX
#define CXXV_BLOB_MAX 8
#endif

namespace toit {
ByteArray* Process::allocate_byte_array(word length, bool force_external) {
  if (nondet_bool()) return null;
  HeapObject* result = cxxv::raw_object(ByteArray::HEADER_SIZE + length);
  cxxv::set_header(result, Program::byte_array_class_id_INDEX, BYTE_ARRAY_TAG);
  ByteArray* bytes = static_cast<ByteArray*>(result);
  bytes->_initialize(length);
  return bytes;
}
}  // namespace toit

int main() {
  cxxv::cxxv_constants();
  cxxv::World world;
  cxxv::make_world(&world);
  Process* process = world.process;

  Object* source = cxxv::nondet_blob(CXXV_BLOB_MAX);
  Object* dest;
  switch (nondet_int()) {
    case 0:
      dest = source;  // The same object (a byte array, or a string: refused).
      break;
    case 1: {
      Instance* slice = cxxv::new_instance(Program::byte_array_slice_class_id_INDEX,
                                           Instance::BYTE_ARRAY_SLICE_TO_INDEX + 1);
      slice->at_put_no_write_barrier(Instance::BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX, source);
      slice->at_put_no_write_barrier(Instance::BYTE_ARRAY_SLICE_FROM_INDEX, cxxv::nondet_smi());
      slice->at_put_no_write_barrier(Instance::BYTE_ARRAY_SLICE_TO_INDEX, cxxv::nondet_smi());
      dest = slice;
      break;
    }
    default:
      dest = cxxv::nondet_blob(CXXV_BLOB_MAX);
      break;
  }
  Object* stack[5];
  stack[4] = source;
  stack[3] = dest;
  stack[2] = cxxv::nondet_smi();  // from
  stack[1] = cxxv::nondet_smi();  // to
  stack[0] = cxxv::nondet_smi();  // dest_index

  // The byte P2 follows, read before the call.
  Blob source_blob;
  bool has_source = source->byte_content(world.program, &source_blob, STRINGS_OR_BYTE_ARRAYS);
  word from = Smi::value(stack[2]);
  word to = Smi::value(stack[1]);
  word dest_index = Smi::value(stack[0]);
  word k = nondet_word();
  bool follow = has_source && 0 <= from && from <= to && to <= source_blob.length() && 0 <= k && k < to - from;
  uint8 expected = follow ? source_blob.address()[from + k] : 0;

  Object* result = primitive_string_write_to_byte_array(process, &stack[4]);

  if (result == dest && follow) {
    MutableBlob dest_blob;
    Error* error;
    CXXV_ASSERT(dest->mutable_byte_content(process, &dest_blob, &error), "P2: the destination is a mutable blob");
    CXXV_ASSERT(dest_blob.address()[dest_index + k] == expected, "P2: memmove semantics");
  }
  return 0;
}

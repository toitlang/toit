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

// Pilot target (b): the message encoder of process_send (src/messaging.cc,
// MessageEncoder::encode_any and its list, slice, map, array and blob
// cases, with Object::byte_content of src/objects.cc), on a
// nondeterministic object graph of the heap model (heap_model.h: header
// and size guaranteed, field values program-controlled).
//
// The real src/messaging.cc and src/objects.cc are compiled unmodified;
// `private`/`protected` are defined to `public` so the heap model can
// build objects with the VM's own setters (no layout effect).
//
// Properties, for every object graph within the bounds of heap_model.h:
//  P1 no out-of-bounds read or write, no invalid pointer, no signed
//     overflow (the encoder reads list sizes, slice bounds and map sizes
//     from fields: f708ad5d fixed three over-reads here);
//  P2 the size pass (no buffer) and the writing pass agree: when the size
//     pass succeeds, the writing pass into a buffer of exactly that size
//     succeeds and writes exactly that many bytes (the primitive allocates
//     the buffer from the size pass: disagreement is a heap overflow).

#define private public
#define protected public
#include "prelude.h"
#include "messaging.cc"
#include "objects.cc"
#undef private
#undef protected

#include "constants.h"
#include "heap_model.h"

using namespace toit;

int main() {
  cxxv::cxxv_constants();
  cxxv::World world;
  cxxv::make_world(&world);
#ifdef CXXV_GENERAL_GRAPH
  // Any object graph of heap_model.h up to CXXV_DEPTH (expensive).
  Object* object = cxxv::nondet_object(&world, CXXV_DEPTH);
#else
  // The collections whose fields f708ad5d bounds (heap_model.h).
  Object* object = cxxv::nondet_collection(&world);
#endif

  MessageEncoder sizer(world.process, null, MESSAGE_FORMAT_IPC, false);
  bool sized = sizer.encode(object);
  if (!sized) return 0;
#ifdef CXXV_NO_WRITE_PASS
  return 0;  // P1 of the size pass only.
#endif
  word size = sizer.size();
  CXXV_ASSERT(size > 0, "P2: a successful encoding is not empty");
  uint8* buffer = static_cast<uint8*>(malloc(size));
  CXXV_ASSUME(buffer != null);
  MessageEncoder writer(world.process, buffer, MESSAGE_FORMAT_IPC, false);
  bool written = writer.encode(object);
  CXXV_ASSERT(written || writer.malloc_failed(), "P2: the writing pass succeeds when the size pass did");
  if (written) CXXV_ASSERT(writer.size() == size, "P2: the writing pass writes the size pass' size");
  free(buffer);
  return 0;
}

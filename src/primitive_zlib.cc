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

#include "process.h"
#include "objects.h"
#include "objects_inline.h"
#include "primitive.h"
#include "nano_zlib.h"

namespace toit {

MODULE_IMPLEMENTATION(zlib, MODULE_ZLIB)

PRIMITIVE(adler32_start) {
  ARGS(SimpleResourceGroup, group)
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  Adler32* adler32 = _new Adler32(group);
  if (!adler32) MALLOC_FAILED;
  proxy->set_external_address(adler32);
  return proxy;
}

PRIMITIVE(adler32_add) {
  ARGS(Adler32, adler32, Blob, data, int, from, int, to, bool, unadd);
  if (!adler32) INVALID_ARGUMENT;
  if (from < 0 || to > data.length() || from > to) OUT_OF_RANGE;
  if (unadd) {
    adler32->unadd(data.address() + from, to - from);
  } else {
    adler32->add(data.address() + from, to - from);
  }
  return process->program()->null_object();
}

PRIMITIVE(adler32_get) {
  ARGS(Adler32, adler32, bool, destructive);
  Error* error = null;
  ByteArray* result = process->allocate_byte_array(4, &error);
  if (result == null) return error;
  ByteArray::Bytes bytes(result);
  adler32->get(bytes.address());
  if (destructive) {
    adler32->resource_group()->unregister_resource(adler32);
    adler32_proxy->set_external_address(static_cast<Adler32*>(null));
  }
  return result;
}

PRIMITIVE(rle_start) {
  ARGS(SimpleResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  ZlibRle* rle = _new ZlibRle(group);
  if (!rle) MALLOC_FAILED;
  proxy->set_external_address(rle);
  return proxy;
}

PRIMITIVE(rle_add) {
  ARGS(ZlibRle, rle, MutableBlob, destination_bytes, int, index, Blob, data, int, from, int, to);
  if (!rle) INVALID_ARGUMENT;
  if (from < 0 || to > data.length() || from > to) OUT_OF_RANGE;
  // We need to return distances packed in 15 bit fields, so we limit the size
  // we attempt in order to prevent an outcome we can't report.
  word destination_length = Utils::min(0x7000, destination_bytes.length());
  to = Utils::min(to, from + 0x7000);
  if (index < 0 || index >= destination_length) OUT_OF_RANGE;
  rle->set_output_buffer(destination_bytes.address(), index, destination_length);
  word read = rle->add(data.address() + from, to - from);
  word written = rle->get_output_index() - index;
  ASSERT(read < 0x8000 && written < 0x8000 && read >= 0 && written >= 0);
  return Smi::from(read | (written << 15));
}

PRIMITIVE(rle_finish) {
  ARGS(ZlibRle, rle, MutableBlob, destination_bytes, int, index);
  word destination_length = Utils::min(0x7000, destination_bytes.length());
  if (index < 0 || index >= destination_length) OUT_OF_RANGE;
  rle->set_output_buffer(destination_bytes.address(), index, destination_length);
  rle->finish();
  word written = rle->get_output_index() - index;
  rle->resource_group()->unregister_resource(rle);
  rle_proxy->set_external_address(static_cast<ZlibRle*>(null));
  return Smi::from(written);
}

}

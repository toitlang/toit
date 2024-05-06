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

#ifdef CONFIG_TOIT_FULL_ZLIB
#include "third_party/miniz/miniz.h"
// It's an include-only library with a .c file.
#include "third_party/miniz/miniz.c"
#endif

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
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Adler32* adler32 = _new Adler32(group);
  if (!adler32) FAIL(MALLOC_FAILED);
  proxy->set_external_address(adler32);
  return proxy;
}

PRIMITIVE(adler32_clone) {
  ARGS(Adler32, parent);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Adler32* child = _new Adler32(static_cast<SimpleResourceGroup*>(parent->resource_group()));
  if (!child) FAIL(MALLOC_FAILED);
  parent->clone(child);
  proxy->set_external_address(child);
  return proxy;
}

PRIMITIVE(adler32_add) {
  ARGS(Adler32, adler32, Blob, data, word, from, word, to, bool, unadd);
  if (!adler32) FAIL(INVALID_ARGUMENT);
  if (from < 0 || to > data.length() || from > to) FAIL(OUT_OF_RANGE);
  if (unadd) {
    adler32->unadd(data.address() + from, to - from);
  } else {
    adler32->add(data.address() + from, to - from);
  }
  return process->null_object();
}

PRIMITIVE(adler32_get) {
  ARGS(Adler32, adler_32, bool, destructive);
  ByteArray* result = process->allocate_byte_array(4);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  adler_32->get(bytes.address());
  if (destructive) {
    adler_32->resource_group()->unregister_resource(adler_32);
    adler_32_proxy->set_external_address(static_cast<Adler32*>(null));
  }
  return result;
}

PRIMITIVE(rle_start) {
#ifndef CONFIG_TOIT_ZLIB_RLE
  FAIL(UNIMPLEMENTED);
#else
  ARGS(SimpleResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  ZlibRle* rle = _new ZlibRle(group);
  if (!rle) FAIL(MALLOC_FAILED);
  proxy->set_external_address(rle);
  return proxy;
#endif
}

PRIMITIVE(rle_add) {
#ifndef CONFIG_TOIT_ZLIB_RLE
  FAIL(UNIMPLEMENTED);
#else
  ARGS(ZlibRle, rle, MutableBlob, destination_bytes, word, index, Blob, data, word, from, word, to);
  if (!rle) FAIL(INVALID_ARGUMENT);
  if (from < 0 || to > data.length() || from > to) FAIL(OUT_OF_RANGE);
  // We need to return distances packed in 15 bit fields, so we limit the size
  // we attempt in order to prevent an outcome we can't report.
  word LIMIT_15_BIT = 0x7000;
  word HARD_LIMIT = 0x8000;
  word destination_length = Utils::min(LIMIT_15_BIT, destination_bytes.length());
  to = Utils::min(to, from + LIMIT_15_BIT);
  if (index < 0 || index >= destination_length) FAIL(OUT_OF_RANGE);
  rle->set_output_buffer(destination_bytes.address(), index, destination_length);
  word read = rle->add(data.address() + from, to - from);
  word written = rle->get_output_index() - index;
  ASSERT(read < HARD_LIMIT && written < HARD_LIMIT && read >= 0 && written >= 0);
  return Smi::from(read | (written << 15));
#endif
}

PRIMITIVE(rle_finish) {
#ifndef CONFIG_TOIT_ZLIB_RLE
  FAIL(UNIMPLEMENTED);
#else
  ARGS(ZlibRle, rle, MutableBlob, destination_bytes, word, index);
  word LIMIT_15_BIT = 0x7000;
  word destination_length = Utils::min(LIMIT_15_BIT, destination_bytes.length());
  if (index < 0 || index >= destination_length) FAIL(OUT_OF_RANGE);
  rle->set_output_buffer(destination_bytes.address(), index, destination_length);
  rle->finish();
  word written = rle->get_output_index() - index;
  rle->resource_group()->unregister_resource(rle);
  rle_proxy->set_external_address(static_cast<ZlibRle*>(null));
  return Smi::from(written);
#endif
}

#ifdef CONFIG_TOIT_FULL_ZLIB

class Zlib : public SimpleResource {
 public:
  TAG(Zlib);

  Zlib(SimpleResourceGroup* group) : SimpleResource(group) {}
  ~Zlib();

  int init_deflate(int compression_level);
  int init_inflate();
  int write(const uint8* data, word length, int* error_return);
  int output_available();
  void get_output(uint8* buffer, word length);
  void close() { closed_ = true; }
  bool closed() const { return closed_; }

 private:
  static const int ZLIB_BUFFER_SIZE = 16384;
  z_stream stream_;
  bool deflate_;
  bool closed_ = false;
  uint8 output_buffer_[ZLIB_BUFFER_SIZE];
};

int Zlib::init_deflate(int compression_level) {
  stream_.zalloc = Z_NULL;
  stream_.zfree = Z_NULL;
  stream_.opaque = null;
  int result = deflateInit(&stream_, compression_level);
  stream_.next_out = &output_buffer_[0];
  stream_.avail_out = ZLIB_BUFFER_SIZE;
  deflate_ = true;
  return result;
}

int Zlib::init_inflate() {
  stream_.zalloc = Z_NULL;
  stream_.zfree = Z_NULL;
  stream_.opaque = null;
  int result = inflateInit(&stream_);
  stream_.next_out = &output_buffer_[0];
  stream_.avail_out = ZLIB_BUFFER_SIZE;
  deflate_ = false;
  return result;
}

Zlib::~Zlib() {
  if (deflate_) {
    deflateEnd(&stream_);
  } else {
    inflateEnd(&stream_);
  }
}

int Zlib::write(const uint8* data, word length, int* error_return) {
  stream_.next_in = const_cast<uint8*>(data);
  stream_.avail_in = length;
  int result = deflate_ ? deflate(&stream_, Z_NO_FLUSH) : inflate(&stream_, Z_NO_FLUSH);
  *error_return = result;
  int written = length - stream_.avail_in;
  return written;
}

int Zlib::output_available() {
  if (closed_) {
    stream_.avail_in = 0;
    if (deflate_) {
      deflate(&stream_, Z_FINISH);
    } else {
      inflate(&stream_, Z_FINISH);
    }
  }
  return ZLIB_BUFFER_SIZE - stream_.avail_out;
}

void Zlib::get_output(uint8* buffer, word length) {
  memcpy(buffer, output_buffer_, length);
  stream_.next_out = &output_buffer_[0];
  stream_.avail_out = ZLIB_BUFFER_SIZE;
}

static Object* zlib_error(Process* process, int error) {
  if (error == Z_MEM_ERROR) FAIL(MALLOC_FAILED);
  printf("Unknown error message %d\n", error);
  FAIL(ERROR);
}

#endif

PRIMITIVE(zlib_init_deflate) {
#ifndef CONFIG_TOIT_FULL_ZLIB
  FAIL(UNIMPLEMENTED);
#else
  ARGS(SimpleResourceGroup, group, int, compression_level)
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Zlib* zlib = _new Zlib(group);
  if (!zlib) FAIL(MALLOC_FAILED);
  int result = zlib->init_deflate(compression_level);
  if (result < 0) {
    delete zlib;
    return zlib_error(process, result);
  }
  proxy->set_external_address(zlib);
  return proxy;
#endif
}

PRIMITIVE(zlib_init_inflate) {
#ifndef CONFIG_TOIT_FULL_ZLIB
  FAIL(UNIMPLEMENTED);
#else
  ARGS(SimpleResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Zlib* zlib = _new Zlib(group);
  if (!zlib) FAIL(MALLOC_FAILED);
  int result = zlib->init_inflate();
  if (result < 0) {
    delete zlib;
    return zlib_error(process, result);
  }
  proxy->set_external_address(zlib);
  return proxy;
#endif
}

PRIMITIVE(zlib_write) {
#ifndef CONFIG_TOIT_FULL_ZLIB
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Zlib, zlib, Blob, data);
  int error;
  int bytes_written = zlib->write(data.address(), data.length(), &error);
  if (error < 0 && error != Z_BUF_ERROR) return zlib_error(process, error);
  return Smi::from(bytes_written);
#endif
}

PRIMITIVE(zlib_read) {
#ifndef CONFIG_TOIT_FULL_ZLIB
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Zlib, zlib);
  word length = zlib->output_available();
  if (length == 0 && zlib->closed()) return process->null_object();
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  zlib->get_output(bytes.address(), length);
  return result;
#endif
}

PRIMITIVE(zlib_close) {
#ifndef CONFIG_TOIT_FULL_ZLIB
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Zlib, zlib);
  zlib->close();
  return process->null_object();
#endif
}

PRIMITIVE(zlib_uninit) {
#ifndef CONFIG_TOIT_FULL_ZLIB
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Zlib, zlib);
  zlib->resource_group()->unregister_resource(zlib);
  zlib_proxy->clear_external_address();
  return process->null_object();
#endif
}

}

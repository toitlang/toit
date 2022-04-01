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

#pragma once

#include "top.h"

namespace toit {

class Buffer {
 public:
  virtual void put_byte(uint8 c) = 0;
  virtual bool has_overflow() = 0;

  void put_int32(int32 value) { put_uint32((uint32) value); }
  void put_int16(int16 value) { put_uint16((uint16) value); }
  void put_int8(int8 value)   { put_uint8((uint8) value); }

  void put_uint8(int8 value) {
    put_byte(value);
  }

  void put_uint16(uint16 value) {
    put_uint8((uint8) (value >> 8));
    put_uint8((uint8) value);
  }

  void put_uint32(uint32 value) {
    for (int i = 3; i >= 0; i--) {
      put_uint8((uint8) (value >> (i << 3)));
    }
  }

  void put_int64(int64 value) {
    long long unsigned int v = value;
    for (int i = 7; i >= 0; i--) {
      put_uint8((uint8) (v >> (i << 3)));
    }
  }

  void put_string(uint8* str) {
    uint8* p = str;
    while (*p) put_byte(*p++);
  }
};

class MallocedBuffer : public Buffer {
 public:
  explicit MallocedBuffer(int length) {
    ASSERT(length > 0);
    _length = length;
    _buffer = reinterpret_cast<uint8*>(malloc(length));
    _pos = 0;
    if (_buffer == null) _length = 0;
  }

  ~MallocedBuffer() {
    free(_buffer);
  }

  virtual void put_byte(uint8 c) {
    if (_pos < _length) _buffer[_pos] = c;
    _pos++;
  }

  bool malloc_failed() { return _length == 0; }
  uint8* content() { return _buffer; }

  virtual bool has_overflow() {
    return _pos >= _length;
  }

  int size() { return _pos; }

 private:
  uint8* _buffer;
  int _length;
  int _pos;
};

class Encoder {
 public:
  Encoder(Buffer* buffer) : _buffer(buffer) {}

  Buffer* buffer() { return _buffer; }

  void write_byte(uint8 c);
  void write_int(int64 value);
  void write_header(int size, uint8 tag);
  void write_double(double value);
  void write_byte_array_header(int length);
  void write_string(const char* string);

 protected:
  Buffer* buffer() const { return _buffer; }

 private:
  Buffer* _buffer;
};

class ProgramOrientedEncoder : public Encoder {
 public:
  ProgramOrientedEncoder(Program* program, Buffer* buffer);

  bool encode(Object* object);

  bool encode_error(Object* type, Object* message, Stack* stack);
  bool encode_error(Object* type, const char* message, Stack* stack);

#ifdef PROFILER
  bool encode_profile(Profiler* profile, String* title, int cutoff);
#endif

  Program* program() { return _program; }

 private:
  Program* _program;
};


} // namespace toit

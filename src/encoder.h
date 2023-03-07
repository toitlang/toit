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
  explicit MallocedBuffer(int length) : buffer_(null) {
    allocate(length);
  }

  void allocate(int length) {
    ASSERT(length > 0);
    ASSERT(buffer_ == null);
    buffer_ = reinterpret_cast<uint8*>(malloc(length));
    length_ = (buffer_ != null) ? length : 0;
    pos_ = 0;
  }

  ~MallocedBuffer() {
    free(buffer_);
  }

  virtual void put_byte(uint8 c) {
    if (pos_ < length_) buffer_[pos_] = c;
    pos_++;
  }

  bool has_content() const { return length_ > 0; }
  uint8* content() const { return buffer_; }

  uint8* take_content() {
    uint8* result = buffer_;
    buffer_ = null;
    length_ = 0;
    return result;
  }

  virtual bool has_overflow() {
    return pos_ >= length_;
  }

  int size() { return pos_; }

 private:
  uint8* buffer_;
  int length_;
  int pos_;
};

class Encoder {
 public:
  Encoder(Buffer* buffer) : buffer_(buffer) {}

  Buffer* buffer() { return buffer_; }

  void write_byte(uint8 c);
  void write_int(int64 value);
  void write_header(int size, uint8 tag);
  void write_double(double value);
  void write_byte_array_header(int length);
  void write_string(const char* string);
  // Always uses the 32 bit encoding even if a smaller one would suffice.  This
  // helps make the size of something predictable.
  void write_int32(int64 value);

 protected:
  Buffer* buffer() const { return buffer_; }

 private:
  Buffer* buffer_;
};

class ProgramOrientedEncoder : public Encoder {
 public:
  ProgramOrientedEncoder(Program* program, Buffer* buffer);

  bool encode(Object* object);

  bool encode_error(Object* type, Object* message, Stack* stack);
  bool encode_error(Object* type, const char* message, Stack* stack);

  bool encode_profile(Profiler* profile, String* title, int cutoff);

  Program* program() { return program_; }

 private:
  Program* program_;
};


} // namespace toit

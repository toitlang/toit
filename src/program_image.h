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

#include <sys/types.h>
#include <functional>

#include "memory.h"
#include "objects.h"
#include "os.h"
#include "tags.h"
#include "top.h"

namespace toit {

class ProgramImage {
 public:
  ProgramImage(void* address, int size)
      : _memory(null), _address(address), _size(size) {}
#ifndef TOIT_FREERTOS
  ProgramImage(ProtectableAlignedMemory* memory)
      : _memory(memory)
      , _address(memory->address())
      , _size(static_cast<int>(memory->byte_size())) {}
#endif

  static ProgramImage invalid() { return ProgramImage(null, 0); }

  bool is_valid() const { return _address != null; }

  // Call back for each pointer.
  void do_pointers(PointerCallback* callback) const;

  Program* program() const { return reinterpret_cast<Program*>(_address); }

  word* begin() const { return reinterpret_cast<word*>(_address); }
  word* end() const { return Utils::address_at(begin(), _size); }

  // The byte_size needed for the unfolded page aligned image.
  int byte_size() const { return _size; }

  // Tells whether addr is inside the image,
  bool address_inside(word* addr) const { return addr >= begin() && addr < end(); }

  void* address() const { return _address; }

  /// Frees the memory.
  /// Uses `delete` for the aligned memory, or `free` for the `void*`.
  /// It is safe to call release of an invalid image.
  void release() {
    if (_memory == null) {
      free(_address);
    } else {
      delete _memory;
    }
    _memory = null;
    _address = null;
  }

 private:
  AlignedMemoryBase* _memory;
  void* _address;
  int _size;
};

class PointerCallback {
 public:
  void object_table(Object**p, int length);
  virtual void object_address(Object** p) = 0;
  virtual void c_address(void** p, bool is_sentinel = false) = 0;
  virtual void literal_data(uint8* p, int count) = 0;
};

#ifndef TOIT_FREERTOS

class RelocationBits;

// Abstraction to stream over a Toit image for relocation.
class ImageInputStream {
 public:
  // Builds the relocation_bits.
  // The relocation bits indicate for each word in the heap (given as [address], [size])
  //   whether the word at that location is a pointer that needs to be adjusted.
  // The returned table must be deleted with `delete`.
  static RelocationBits* build_relocation_bits(const ProgramImage& image);

  ImageInputStream(const ProgramImage& image,
                   RelocationBits* relocation_bits);

  int words_to_read();
  int read(word* buffer);
  bool eos() { return current >= _image.end(); }

  ProgramImage image() const { return _image; }

 private:
  ProgramImage _image;
  RelocationBits* relocation_bits;
  word* current;
  int index;
};

#endif  // TOIT_FREERTOS

// Abstraction to write a Toit image (counter part of ImageInputStream).
class ImageOutputStream {
 public:
  TAG(ImageOutputStream);
  ImageOutputStream(ProgramImage image);

  static const int CHUNK_SIZE = 1 + WORD_BIT_SIZE;

  void* cursor() const { return current; }
  bool empty() const { return current == _image.begin(); }

  void write(const word* buffer, int size, word* output = null);

  ProgramImage image() const { return _image; }

 private:
  ProgramImage _image;
  word* current;
};

} // namespace toit

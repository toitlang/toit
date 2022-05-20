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

// Fordward declarations.
enum class SnapshotTypeTag;
class EmittingSnapshotWriter;

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
  AlignedMemoryBase* memory() const { return _memory; }

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
  void object_table(Object** p, int length);
  virtual void object_address(Object** p) = 0;
  // When [is_sentinel] is true, then the pointer is delimiting a memory
  // area and is thus allowed to point to invalid memory (by one word).
  virtual void c_address(void** p, bool is_sentinel = false) = 0;
};

#ifndef TOIT_FREERTOS

class Snapshot {
 public:
  Snapshot(const uint8* buffer, int size)
      : _buffer(buffer), _size(size) { }

  static Snapshot invalid() { return Snapshot(null, 0); }

  bool is_valid() const { return _buffer != null; }

  ProgramImage read_image(const uint8* id);
  Object* read_object(Process* process);

  const uint8* buffer() const { return _buffer; }
  int size() const { return _size; }

 private:
  const uint8* const _buffer;
  const int _size;
};

class SnapshotAllocator {
 public:
  virtual bool initialize(int normal_block_count,
                          int external_pointer_count,
                          int external_int32_count,
                          int external_byte_count) = 0;
  virtual HeapObject* allocate_object(TypeTag tag, int length) = 0;
  virtual Object** allocate_external_pointers(int count) = 0;
  virtual uint16* allocate_external_uint16s(int count) = 0;
  virtual int32* allocate_external_int32s(int count) = 0;
  virtual uint8* allocate_external_bytes(int count) = 0;
};

class SnapshotReader {
 protected:
  SnapshotReader(const uint8* buffer, int length, SnapshotAllocator* allocator);
  ~SnapshotReader();

  bool initialize(int snapshot_size,
                  int normal_block_count,
                  int external_pointer_count,
                  int external_int32_count,
                  int external_byte_count,
                  int table_length,
                  int large_integer_id);

  virtual bool read_header() = 0;

 public:
  uword read_cardinal();
  uint64 read_cardinal64();
  double read_double();
  int64 read_int64();
  Object* read_object();
  uint8 read_byte();
  // Allocates the returned list using [allocate].
  List<int32> read_external_list_int32();
  // Allocates the returned list using [allocate].
  List<uint16> read_external_list_uint16();
  // Allocates the returned list using [allocate].
  List<uint8> read_external_list_uint8();

  // Read malloc'ed table of objects.
  Object** read_external_object_table(int* length);

  void register_class_bits(uint16* class_bits, int length) {
    _class_bits = class_bits;
    _class_bits_length = length;
  }

  bool eos() { return _pos == _snapshot_size; }

 protected:
  Object* read_integer(bool is_negated);
  uint16 read_uint16();
  int32 read_int32();
  uint32 read_uint32();
  uint64 read_uint64();
  void read_object_header(SnapshotTypeTag* tag, int* extra);
  Object* read_heap_object();

 private:
  HeapObject* allocate_object(TypeTag tag, int length);
  Object** allocate_external_pointers(int count);
  uint16* allocate_external_uint16s(int count);
  int32* allocate_external_int32s(int count);
  uint8* allocate_external_bytes(int count);

  const uint8* const _buffer;
  int const _length;
  SnapshotAllocator* _allocator;

  int _large_integer_id;  // Set in `read_header`.
  int _snapshot_size;
  int _index;
  int _pos;
  HeapObject** _table;
  int _table_length;
  uint16* _class_bits;
  int _class_bits_length;
};

class SnapshotWriter {
 public:
  virtual void write_cardinal(uword value) = 0;
  virtual void write_double(double value) = 0;
  virtual void write_object(Object* object) = 0;
  virtual void write_byte(uint8 value) = 0;
  virtual void write_external_object_table(Object** table, int length) = 0;
  virtual void write_external_list_int32(List<int32> list) = 0;
  virtual void write_external_list_uint16(List<uint16> list) = 0;
  virtual void write_external_list_uint8(List<uint8> list) = 0;

};

class SnapshotGenerator {
 public:
  explicit SnapshotGenerator(Program* program) : _program(program) { }
  ~SnapshotGenerator();

  void generate(Program* program);
  void generate(Object* object, Process* process);

  uint8* the_buffer() const { return _buffer; }
  int the_length() const { return _length; }

  // Transfers ownership of the buffer to the caller.
  // The buffer should be released with `free`.
  uint8* take_buffer(int* length);

 private:
  Program* const _program;
  uint8* _buffer = null;
  int _length = 0;

  int large_integer_class_id();

  void generate(int header_byte_size,
                std::function<void (EmittingSnapshotWriter*)> write_header,
                std::function<void (SnapshotWriter*)> write_object);
};

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

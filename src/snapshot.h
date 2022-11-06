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
#include "uuid.h"

namespace toit {

// Fordward declarations.
enum class SnapshotTypeTag;
class EmittingSnapshotWriter;

class ProgramImage {
 public:
  ProgramImage(void* address, int size)
      : memory_(null), address_(address), size_(size) {}
#ifndef TOIT_FREERTOS
  ProgramImage(ProtectableAlignedMemory* memory)
      : memory_(memory)
      , address_(memory->address())
      , size_(static_cast<int>(memory->byte_size())) {}
#endif

  static ProgramImage invalid() { return ProgramImage(null, 0); }

  bool is_valid() const { return address_ != null; }

  // Call back for each pointer.
  void do_pointers(PointerCallback* callback) const;

  Program* program() const { return reinterpret_cast<Program*>(address_); }

  word* begin() const { return reinterpret_cast<word*>(address_); }
  word* end() const { return Utils::address_at(begin(), size_); }

  // The byte_size needed for the unfolded page aligned image.
  int byte_size() const { return size_; }

  // Tells whether addr is inside the image,
  bool address_inside(word* addr) const { return addr >= begin() && addr < end(); }

  void* address() const { return address_; }
  AlignedMemoryBase* memory() const { return memory_; }

  /// Frees the memory.
  /// Uses `delete` for the aligned memory, or `free` for the `void*`.
  /// It is safe to call release of an invalid image.
  void release() {
    if (memory_ == null) {
      free(address_);
    } else {
      delete memory_;
    }
    memory_ = null;
    address_ = null;
  }

 private:
  AlignedMemoryBase* memory_;
  void* address_;
  int size_;
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
      : buffer_(buffer), size_(size) {}

  static Snapshot invalid() { return Snapshot(null, 0); }

  bool is_valid() const { return buffer_ != null; }

  ProgramImage read_image(const uint8* id);
  Object* read_object(Process* process);

  const uint8* buffer() const { return buffer_; }
  int size() const { return size_; }

 private:
  const uint8* const buffer_;
  const int size_;
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
    class_bits_ = class_bits;
    class_bits_length_ = length;
  }

  bool eos() { return pos_ == snapshot_size_; }

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

  const uint8* const buffer_;
  int const length_;
  SnapshotAllocator* allocator_;

  int large_integer_id_;  // Set in `read_header`.
  int snapshot_size_;
  int index_;
  int pos_;
  HeapObject** table_;
  int table_length_;
  uint16* class_bits_;
  int class_bits_length_;
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
  explicit SnapshotGenerator(Program* program) : program_(program) {}
  ~SnapshotGenerator();

  void generate(Program* program);
  void generate(Object* object, Process* process);

  uint8* the_buffer() const { return buffer_; }
  int the_length() const { return length_; }

  // Transfers ownership of the buffer to the caller.
  // The buffer should be released with `free`.
  uint8* take_buffer(int* length);

 private:
  Program* const program_;
  uint8* buffer_ = null;
  int length_ = 0;

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
  bool eos() { return current >= image_.end(); }

  ProgramImage image() const { return image_; }

 private:
  ProgramImage image_;
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

  void* cursor() const { return current_; }
  bool empty() const { return current_ == image_.begin(); }

  void write(const word* buffer, int size, word* output = null);

  ProgramImage image() const { return image_; }

  const uint8* program_id() const { return &program_id_[0]; }
  void set_program_id(const uint8* id);

  int program_size() const { return program_size_; }
  void set_program_size(int size) { program_size_ = size; }

 private:
  ProgramImage image_;
  word* current_;

  uint8 program_id_[UUID_SIZE];
  int program_size_ = 0;
};

} // namespace toit

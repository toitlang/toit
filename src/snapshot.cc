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

#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "snapshot.h"
#include "objects_inline.h"
#include "program_heap.h"
#include "os.h"
#include "process.h"
#include "uuid.h"
#include "vm.h"

namespace toit {

#ifndef TOIT_FREERTOS

enum class SnapshotTypeTag {
  OBJECT_TAG = 0,
  IN_TABLE_TAG,
  BACK_REFERENCE_TAG,
  POSITIVE_SMI_TAG,
  NEGATIVE_SMI_TAG,  // Last element must be tested in static_assert below.
};
static const int OBJECT_HEADER_TYPE_SIZE = 3;
static_assert(static_cast<int>(SnapshotTypeTag::NEGATIVE_SMI_TAG) < (1 << OBJECT_HEADER_TYPE_SIZE),
              "Invalid object header width");
static const int OBJECT_HEADER_TYPE_MASK = (1 << OBJECT_HEADER_TYPE_SIZE) - 1;

static const uint32 PROGRAM_SNAPSHOT_MAGIC = 70177017;  // Toit toit.

static const int PROGRAM_SNAPSHOT_HEADER_BYTE_SIZE = 8 * UINT32_SIZE;

namespace {

template <typename V>
class Node {
 public:
  Node(uword key, const V& value) : key(key), value(value), left(null), right(null) {}
  uword key;
  V value;
  Node<V>* left;
  Node<V>* right;
};

template <typename V>
class BinaryTree {
 public:
  BinaryTree() : ref_count(_new int(1)) {}
  BinaryTree(const BinaryTree& other)
      : ref_count(other.ref_count)
      , size_(other.size_)
      , root(other.root) {
    (*ref_count)++;
  }

  ~BinaryTree() {
    (*ref_count)--;
    if (*ref_count == 0) {
      delete_nodes(root);
      delete ref_count;
    }
  }

  BinaryTree& operator=(const BinaryTree& other) {
    (*other.ref_count)++;
    (*ref_count)--;
    if (*ref_count == 0) {
      delete_nodes(root);
      delete ref_count;
    }
    ref_count = other.ref_count;
    size_ = other.size_;
    root = other.root;
    return *this;
  }

  void insert(uword key, const V& value) {
    ASSERT((*ref_count) == 1);
    // Mangle the key to give a more uniform distribution.
    key = hash(key);
    if (root == null) {
      size_++;
      root = _new Node<V>(key, value);
      return;
    }
    auto current = root;
    while (true) {
      if (key == current->key) {
        current->value = value;
        return;
      }
      if (key < current->key) {
        if (current->left == null) {
          size_++;
          current->left = _new Node<V>(key, value);
          return;
        }
        current = current->left;
        continue;
      }
      ASSERT(key > current->key);
      if (current->right == null) {
        size_++;
        current->right = _new Node<V>(key, value);
        return;
      }
      current = current->right;
    }
  }

  const std::pair<uword, V>* find(uword key) const {
    // Mangle the key to give a more uniform distribution.
    key = hash(key);
    auto current = root;
    while (true) {
      if (current == null) return null;
      if (key == current->key) {
        found.first = key;
        found.second = current->value;
        return &found;
      }
      if (key < current->key) {
        current = current->left;
      } else {
        current = current->right;
      }
    }
  }

  int size() const { return size_; }

 private:
  int* ref_count;
  int size_ = 0;
  Node<V>* root = null;
  mutable std::pair<uword, V> found;

  void delete_nodes(Node<V>* node) {
    if (node == null) return;
    delete_nodes(node->left);
    delete_nodes(node->right);
    delete node;
  }

  uword hash(uword x) const {
    // Via https://github.com/skeeto/hash-prospector (Unlicense).
    x ^= x >> 16;
    x *= UINT32_C(0x7feb352d);
    x ^= x >> 15;
    x *= UINT32_C(0x846ca68b);
    x ^= x >> 16;
    return x;
  }
};

class BinaryTreeSet {
 public:
  void insert(uword key) { tree.insert(key, true); }
  const std::pair<uword, bool>* find(uword key) const {
    return tree.find(key);
  }
  const std::pair<uword, bool>* end() const { return null; }

  int size() const { return tree.size(); }

 private:
  BinaryTree<bool> tree;
};

template <typename V>
class BinaryTreeMap {
 public:
  void emplace(uword key, const V& value) { tree.insert(key, value); }
  const std::pair<uword, V>* find(uword key) const {
    return tree.find(key);
  }
  const std::pair<uword, V>* end() const { return null; }

  int size() const { return tree.size(); }

 private:
  BinaryTree<V> tree;
};

static int _align(int byte_size, int word_size = WORD_SIZE) {
  return (byte_size + (word_size - 1)) & ~(word_size - 1);
}

class HeapAllocator : public SnapshotAllocator {
 public:
  bool initialize(int normal_block_count,
                  int external_pointer_count,
                  int external_int32_count,
                  int external_byte_count) override {
    normal_block_count_ = normal_block_count;
    external_pointer_count_ = external_pointer_count;
    _external_int32_count = external_int32_count;
    external_byte_count_ = external_byte_count;
    return true;
  }

  uint8* allocate_external_bytes(int count) override {
    return unvoid_cast<uint8*>(allocate_external(count));
  }

  Object** allocate_external_pointers(int count) override {
    return unvoid_cast<Object**>(allocate_external(count * sizeof(Object*)));
  }
  uint16* allocate_external_uint16s(int count) override {
    ASSERT(count / 2 <= _external_int32_count);
    return unvoid_cast<uint16*>(allocate_external(count * 2));
  }
  int32* allocate_external_int32s(int count) override {
    ASSERT(count <= _external_int32_count);
    return unvoid_cast<int32*>(allocate_external(count * 4));
  }

  int normal_block_count() const { return normal_block_count_; }
  int external_pointer_count() const { return external_pointer_count_; }
  int external_int32_count() const { return _external_int32_count; }
  int external_byte_count() const { return external_byte_count_; }

 protected:
  virtual void* allocate_external(int byte_size) = 0;

 private:
  int normal_block_count_;
  int external_pointer_count_;
  int _external_int32_count;
  int external_byte_count_;
};

/// A virtual allocator with a given word size.
/// The allocator mimics the heap allocations in the ImageAllocator for the
/// given platform, and is used to determine how many blocks should be used
/// for a program when it's deserialized.
class SizedVirtualAllocator {
 public:
  SizedVirtualAllocator(int word_size)
      : word_size_(word_size)
      , limit(ProgramHeap::max_allocation_size(word_size)) {}

  HeapObject* allocate_object(TypeTag tag, int length);

  void allocate_integer(int64 value) {
    if ((word_size_ == 4 && Smi::is_valid32(value)) ||
        (word_size_ == 8 && Smi::is_valid64(value))) {
      return;
    }
    allocate_object(TypeTag::LARGE_INTEGER_TAG, 0);
  }

  void allocate_external_pointers(int count) {
    external_pointer_count_ += count;
  }

  void allocate_external_int32s(int count) {
    int required_int32s = Utils::round_up(count, word_size_ / 4);
    _external_int32_count += required_int32s;
  }

  void allocate_external_uint16s(int count) {
    // For simplicity use the same space as the 32-bit arrays.
    int required_int32s = Utils::round_up(count, 2);
    allocate_external_int32s(required_int32s);
  }

  void allocate_external_bytes(int count) {
    external_byte_count_ += Utils::round_up(count, word_size_);
  }

  int normal_block_count() const { return normal_block_count_; }
  int external_pointer_count() const {  return external_pointer_count_; }
  int external_int32_count() const {  return _external_int32_count; }
  int external_byte_count() const {  return external_byte_count_; }

 private:
  int word_size_;
  const int limit;
  int top = 0;
  int normal_block_count_ = 0;
  int external_pointer_count_ = 0;
  int _external_int32_count = 0;
  int external_byte_count_ = 0;
};

class VirtualAllocator : public SnapshotAllocator {
 public:
  VirtualAllocator()
      : _allocator32(4)
      , _allocator64(8) {}

  bool initialize(int normal_block_count,
                  int external_pointer_count,
                  int external_int32_count,
                  int external_byte_count) {
    // We are using the virtual allocator to find these values.
    UNREACHABLE();
    return true;
  }

  HeapObject* allocate_object(TypeTag tag, int length) {
    _allocator32.allocate_object(tag, length);
    _allocator64.allocate_object(tag, length);
    return null;
  }

  Object* allocate_integer(int64 value) {
    _allocator32.allocate_integer(value);
    _allocator64.allocate_integer(value);
    return null;
  }

  Object** allocate_external_pointers(int count) {
    _allocator32.allocate_external_pointers(count);
    _allocator64.allocate_external_pointers(count);
    return null;
  }

  int32* allocate_external_int32s(int count) {
    _allocator32.allocate_external_int32s(count);
    _allocator64.allocate_external_int32s(count);
    return null;
  }

  uint16* allocate_external_uint16s(int count) {
    _allocator32.allocate_external_uint16s(count);
    _allocator64.allocate_external_uint16s(count);
    return null;
  }

  uint8* allocate_external_bytes(int count) {
    _allocator32.allocate_external_bytes(count);
    _allocator64.allocate_external_bytes(count);
    return null;
  }

  int normal_block_count(int word_size) const {
    return word_size == 4
        ? _allocator32.normal_block_count()
        : _allocator64.normal_block_count();
  }
  int external_pointer_count(int word_size) const {
    return word_size == 4
        ? _allocator32.external_pointer_count()
        : _allocator64.external_pointer_count();
  }
  int external_int32_count(int word_size) const {
    return word_size == 4
        ? _allocator32.external_int32_count()
        : _allocator64.external_int32_count();
  }
  int external_byte_count(int word_size) const {
    return word_size == 4
        ? _allocator32.external_byte_count()
        : _allocator64.external_byte_count();
  }

 private:
  SizedVirtualAllocator _allocator32;
  SizedVirtualAllocator _allocator64;
};

}

class ImageAllocator : public HeapAllocator {
 public:
  bool initialize(int normal_block_count,
                  int external_pointer_count,
                  int external_int32_count,
                  int external_byte_count) override;

  HeapObject* allocate_object(TypeTag tag, int length) override;

  ProtectableAlignedMemory* image() const { return image_; }

  void* memory() const { return memory_; }

  void set_program(Program* program) { program_ = program; }

  void expand();

 protected:
  void* allocate_external(int byte_size) override;

 private:
  ProtectableAlignedMemory* image_ = null;
  // Memory is split into two sections: external (off-heap), and heap memory.
  // The current unused external memory starts at [external_top_], whereas
  //   the unused heap memory starts at [block_top_].
  void* memory_ = null;
  void* external_top_ = null;
  void* block_top_ = null;

  Program* program_ = null;

  // Returns the byte_size needed for the unfolded page aligned image.
  uword image_byte_size();

  // Returns the byte_size needed for the external (off-heap) memory at the head of the image.
  uword external_size();
};

template <typename T>
using WorkAroundSet = BinaryTreeSet;

template <typename K, typename V>
using WorkAroundMap = BinaryTreeMap<V>;

class ImageSnapshotReader : public SnapshotReader {
 public:
  ImageSnapshotReader(const uint8* buffer, int length)
    : SnapshotReader(buffer, length, &image_allocator_) {}

  // Reads the snapshot.
  ProgramImage read_image(const uint8* id);

 protected:
  bool read_header();

 private:
  ImageAllocator image_allocator_;
  Program* program_ = null;
};

class BaseSnapshotWriter : public SnapshotWriter {
 public:
  BaseSnapshotWriter(int large_integer_class_id,
                     Program* program)
      : large_integer_class_id_(large_integer_class_id)
      , program_(program) {}

  void write_byte(uint8 value) = 0;
  void write_cardinal(uword value);
  void write_double(double value);
  void write_object(Object* object);
  void write_external_object_table(Object** table, int length);
  void write_external_list_int32(List<int32> list);
  void write_external_list_uint16(List<uint16> list);
  void write_external_list_uint8(List<uint8> list);

 protected:
  VirtualAllocator allocator_;

  virtual void write_bytes(uint8* data, int length) = 0;

  /// Whether the object with the given key is a back reference.
  /// Fills the back_reference_id if the object is a back reference.
  virtual bool is_back_reference(uword object_key, int* back_reference_id) = 0;
  /// Whether the object with the given key will be the target of a
  ///   back reference.
  /// The result of this call does not change the size of the generated snapshot.
  virtual bool is_back_reference_target(uword object_key) = 0;

  int large_integer_class_id() const { return large_integer_class_id_; }

 private:
  int const large_integer_class_id_;

  Program* const program_;

  void write_object_header(SnapshotTypeTag tag, int extra = 0) {
    write_cardinal(static_cast<int>(tag) + (extra << OBJECT_HEADER_TYPE_SIZE));
  }
  void write_reference(int index);
  void write_heap_object(HeapObject* object);
  void write_integer(int64 value);
  void write_cardinal64(uint64 value);
  void write_uint16(uint16 value);
  void write_int32(int32 value);
  void write_uint64(uint64 value);
};

class CollectingSnapshotWriter : public BaseSnapshotWriter {
 public:
  // Forward constructor.
  using BaseSnapshotWriter::BaseSnapshotWriter;

  void write_byte(uint8 value);

  void reserve_header(int header_byte_size);

  int length() const { return length_; }
  const WorkAroundSet<uword>& back_reference_targets() const { return back_reference_targets_; }

 protected:
  void write_bytes(uint8* data, int length);

  bool is_back_reference(uword object_key, int* back_reference_id);
  bool is_back_reference_target(uword object_key);

 private:
  int length_ = 0;
  WorkAroundSet<uword> seen_;
  WorkAroundSet<uword> back_reference_targets_;
};

class EmittingSnapshotWriter : public BaseSnapshotWriter {
 public:
  EmittingSnapshotWriter(uint8* buffer,
                         int length,
                         const WorkAroundSet<uword>& back_reference_targets,
                         int large_integer_class_id,
                         Program* program)
      : BaseSnapshotWriter(large_integer_class_id, program)
      , buffer_(buffer)
      , length_(length)
      , back_reference_targets_(back_reference_targets) {}

  void write_byte(uint8 value);

  void reserve_header(int header_byte_size);

  // Must be called last, since it uses the data that was accumulated by the
  //   virtual allocator.
  void write_program_snapshot_header();

  int remaining() const { return length_ - pos_; }

 protected:
  void write_bytes(uint8* data, int length);

  bool is_back_reference(uword object_key, int* back_reference_id);
  bool is_back_reference_target(uword object_key);

 private:
  uint8* const buffer_;
  int const length_;
  WorkAroundSet<uword> const back_reference_targets_;
  WorkAroundMap<uword, int> back_reference_mapping_;
  int pos_ = 0;
  int back_reference_index_ = 0;

  /// Returns the new offset.
  int write_uint32_at(int byte_offset, uint32 value);
};

ProgramImage Snapshot::read_image(const uint8* id) {
  ImageSnapshotReader reader(buffer_, size_);
  return reader.read_image(id);
}

SnapshotReader::SnapshotReader(const uint8* buffer, int length, SnapshotAllocator* allocator)
    : buffer_(buffer)
    , length_(length)
    , allocator_(allocator)
    , large_integer_id_(-1)
    , snapshot_size_(0)
    , index_(0)
    , pos_(0)
    , table_(null) {}

SnapshotReader::~SnapshotReader() {
  delete[] table_;
}

bool SnapshotReader::initialize(int snapshot_size,
                                int normal_block_count,
                                int external_pointer_count,
                                int external_int32_count,
                                int external_byte_count,
                                int table_length,
                                int large_integer_id) {
  snapshot_size_ = snapshot_size;
  bool succeeded = allocator_->initialize(normal_block_count,
                                          external_pointer_count,
                                          external_int32_count,
                                          external_byte_count);
  if (!succeeded) return false;
  table_length_ = table_length;
  table_ = _new HeapObject*[table_length_];
  large_integer_id_ = large_integer_id;
  return table_ != null;
}

HeapObject* SnapshotReader::allocate_object(TypeTag tag, int length) {
  return allocator_->allocate_object(tag, length);
}
Object** SnapshotReader::allocate_external_pointers(int count) {
  return allocator_->allocate_external_pointers(count);
}
uint16* SnapshotReader::allocate_external_uint16s(int count) {
  return allocator_->allocate_external_uint16s(count);
}
int32* SnapshotReader::allocate_external_int32s(int count) {
  return allocator_->allocate_external_int32s(count);
}
uint8* SnapshotReader::allocate_external_bytes(int count) {
  return allocator_->allocate_external_bytes(count);
}

// Returns object table length.
bool ImageSnapshotReader::read_header() {
  uint32 magic = read_uint32();
  if (magic != PROGRAM_SNAPSHOT_MAGIC) {
    printf("Magic marker in snapshot is %x!\n", magic);
    exit(1);
  }
  int snapshot_size = read_uint32();
  int encoded_block_count = read_uint32();
  int block_count32 = encoded_block_count >> 16;
  int block_count64 = encoded_block_count & 0xFFFF;
  int normal_block_count = sizeof(word) == 4 ? block_count32 : block_count64;
  int external_pointer_count = read_uint32();
  int external_int32_count = read_uint32();
  int external_byte_count = read_uint32();
  int table_length = read_uint32();
  int large_integer_id = read_uint32();
  return initialize(snapshot_size,
                    normal_block_count,
                    external_pointer_count,
                    external_int32_count,
                    external_byte_count,
                    table_length,
                    large_integer_id);
}

uint32 SnapshotReader::read_uint32() {
  uint8 bytes[4];
  for (int i = 0; i < 4; i++) bytes[i] = read_byte();
  return bit_cast<uint32>(bytes);
}

uint64 SnapshotReader::read_uint64() {
  uint8 bytes[8];
  for (int i = 0; i < 8; i++) bytes[i] = read_byte();
  return bit_cast<uint64>(bytes);
}

void SnapshotReader::read_object_header(SnapshotTypeTag* tag, int* extra) {
  int header = read_cardinal();
  *tag = static_cast<SnapshotTypeTag>(header & OBJECT_HEADER_TYPE_MASK);
  *extra = header >> OBJECT_HEADER_TYPE_SIZE;
}

uword SnapshotReader::read_cardinal() {
  uword result = 0;
  uint8 byte = read_byte();
  int shift = 0;
  while (byte >= 128) {
    result += (((uword) byte) - 128) << shift;
    shift += 7;
    byte = read_byte();
  }
  result += ((uword) byte) << shift;
  return result;
}

uint64 SnapshotReader::read_cardinal64() {
  uint64 result = 0;
  uint8 byte = read_byte();
  int shift = 0;
  while (byte >= 128) {
    result += (((uint64) byte) - 128) << shift;
    shift += 7;
    byte = read_byte();
  }
  result += ((uint64) byte) << shift;
  // The `+ 1` is for the negative case.
  ASSERT(result <= static_cast<uint64>(INT64_MAX) + 1);
  return result;
}

uint8 SnapshotReader::read_byte() {
  ASSERT(pos_ < length_);
  return buffer_[pos_++];
}

double SnapshotReader::read_double() {
  uint8 bytes[8];
  for (int i = 0; i < 8; i++) bytes[i] = read_byte();
  return bit_cast<double>(bytes);
}

uint16 SnapshotReader::read_uint16() {
  uint8 bytes[2];
  for (int i = 0; i < 2; i++) bytes[i] = read_byte();
  return bit_cast<uint16>(bytes);
}

int32 SnapshotReader::read_int32() {
  uint8 bytes[4];
  for (int i = 0; i < 4; i++) bytes[i] = read_byte();
  return bit_cast<int32>(bytes);
}

int64 SnapshotReader::read_int64() {
  uint8 bytes[8];
  for (int i = 0; i < 8; i++) bytes[i] = read_byte();
  return bit_cast<int64>(bytes);
}

Object* SnapshotReader::read_integer(bool is_negated) {
  int64 value = static_cast<int64>(read_cardinal64());
  if (is_negated) value = -value;
  if (Smi::is_valid(value)) return Smi::from(value);
  auto large_integer_class_bits = class_bits_[large_integer_id_];
  TypeTag class_tag = Program::class_tag_from_class_bits(large_integer_class_bits);
  LargeInteger* result = static_cast<LargeInteger*>(allocate_object(TypeTag::LARGE_INTEGER_TAG, 0));
  result->_set_header(Smi::from(large_integer_id_), class_tag);
  result->_set_value(value);
  return result;
}

static void allocation_size(TypeTag heap_tag, int optional_length,
                            int* word_count, int* extra_bytes) {
  switch (heap_tag) {
    case TypeTag::ARRAY_TAG:
      return Array::allocation_size(optional_length, word_count, extra_bytes);
    case TypeTag::BYTE_ARRAY_TAG:
      return ByteArray::snapshot_allocation_size(optional_length, word_count, extra_bytes);
    case TypeTag::STRING_TAG:
      return String::snapshot_allocation_size(optional_length, word_count, extra_bytes);
    case TypeTag::ODDBALL_TAG:
      return HeapObject::allocation_size(word_count, extra_bytes);
    case TypeTag::INSTANCE_TAG:
      return Instance::allocation_size(optional_length, word_count, extra_bytes);
    case TypeTag::DOUBLE_TAG:
      return Double::allocation_size(word_count, extra_bytes);
    case TypeTag::LARGE_INTEGER_TAG:
      return LargeInteger::allocation_size(word_count, extra_bytes);
    default:
      FATAL("Unexpected class tag");
  }
}

Object* SnapshotReader::read_object() {
  SnapshotTypeTag type;
  int extra;
  read_object_header(&type, &extra);
  switch (type) {
    case SnapshotTypeTag::POSITIVE_SMI_TAG: return read_integer(false);
    case SnapshotTypeTag::NEGATIVE_SMI_TAG: return read_integer(true);
    case SnapshotTypeTag::BACK_REFERENCE_TAG: return table_[extra];
    case SnapshotTypeTag::OBJECT_TAG:
    case SnapshotTypeTag::IN_TABLE_TAG:
      // Handled here.
      break;
  }
  bool in_table = type == SnapshotTypeTag::IN_TABLE_TAG;
  int optional_length = extra;
  TypeTag heap_tag = (TypeTag) (read_byte());
  HeapObject* result = allocate_object(heap_tag, optional_length);
  if (in_table) table_[index_++] = result;
  result->_set_header(Smi::cast(read_object()));
  ASSERT((0 <= result->class_id()->value() && result->class_id()->value() < class_bits_length_));
  ASSERT(ARRAY_TAG <= result->class_tag() && result->class_tag() <= LARGE_INTEGER_TAG);
  switch (heap_tag) {
    case TypeTag::ARRAY_TAG:
      static_cast<Array*>(result)->read_content(this, optional_length);
      break;
    case TypeTag::BYTE_ARRAY_TAG:
      static_cast<ByteArray*>(result)->read_content(this, optional_length);
      break;
    case TypeTag::STRING_TAG:
      static_cast<String*>(result)->read_content(this, optional_length);
      break;
    case TypeTag::ODDBALL_TAG:
      // Oddballs have no body parts.
      break;
    case TypeTag::INSTANCE_TAG:
      static_cast<Instance*>(result)->read_content(this);
      break;
    case TypeTag::DOUBLE_TAG:
      static_cast<Double*>(result)->read_content(this);
      break;
    case TypeTag::LARGE_INTEGER_TAG:
      FATAL("Should not read large integer from snapshot");
    default:
      FATAL("Unexpected class tag");
  }
  return result;
}

List<int32> SnapshotReader::read_external_list_int32() {
  int length = read_int32();
  int32* data = allocate_external_int32s(length);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(data), WORD_SIZE));
  List<int32> result(data, length);
  for (int i = 0; i < length; i++) {
    result[i] = read_int32();
  }
  return result;
}

List<uint16> SnapshotReader::read_external_list_uint16() {
  int length = read_int32();
  uint16* data = allocate_external_uint16s(length);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(data), WORD_SIZE));
  List<uint16> result(data, length);
  for (int i = 0; i < length; i++) {
    result[i] = read_uint16();
  }
  return result;
}

List<uint8> SnapshotReader::read_external_list_uint8() {
  int length = read_int32();
  uint8* data = allocate_external_bytes(length);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(data), WORD_SIZE));
  memcpy(data, &buffer_[pos_], length);
  pos_ += length;
  return List<uint8>(data, length);
}

Object** SnapshotReader::read_external_object_table(int* length) {
  int n = read_cardinal();
  Object** table = allocate_external_pointers(n);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(table), WORD_SIZE));
  for (int i = 0; i < n; i++) {
    table[i] = read_object();
  }
  *length = n;
  return table;
}

HeapObject* SizedVirtualAllocator::allocate_object(TypeTag tag, int length) {
  int word_count, extra_bytes;
  allocation_size(tag, length, &word_count, &extra_bytes);
  int byte_size = _align(word_count * word_size_ + extra_bytes, word_size_);
  ASSERT(byte_size > 0 && Utils::is_aligned(byte_size, word_size_));
  if (top == 0) {
    normal_block_count_++;
    top += byte_size;
  } else {
    if (top + byte_size > limit) {
      top = 0;
      allocate_object(tag, length);
    } else {
      top += byte_size;
    }
  }
  return null;
}

uword ImageAllocator::external_size() {
  int summed_allocations =
      Utils::round_up(sizeof(Program), WORD_SIZE) +
      external_pointer_count() * WORD_SIZE +
      Utils::round_up(external_int32_count() * sizeof(int32), WORD_SIZE) +
      Utils::round_up(external_byte_count(), WORD_SIZE);
  return Utils::round_up(summed_allocations, TOIT_PAGE_SIZE); // Aligned off-heap.
}

uword ImageAllocator::image_byte_size() {
  return external_size() + TOIT_PAGE_SIZE * normal_block_count();
}

bool ImageAllocator::initialize(int normal_block_count,
                  int external_pointer_count,
                  int external_int32_count,
                  int external_byte_count) {
  HeapAllocator::initialize(normal_block_count,
                            external_pointer_count,
                            external_int32_count,
                            external_byte_count);

  int memory_byte_size = image_byte_size();
  // Memory is split into two sections:
  //  1. external (off-heap)
  //  2. heap/block
  // Heap memory must be chunked into blocks of TOIT_PAGE_SIZE so that it can be
  // used more uniformly with the rest of the memory. (For example GC).
  image_ = _new ProtectableAlignedMemory(memory_byte_size, TOIT_PAGE_SIZE);
  memory_ = image_->address();
  if (memory_ == null) return false;

#ifndef TOIT_DEBUG
  // Keep the uninitialized 0xcd markers in debug mode, but otherwise
  // initialize the memory to 0 to make the image more deterministic.
  memset(memory_, 0, memory_byte_size);
#endif
  external_top_ = memory_;
  void* const external_end = Utils::address_at(external_top_, external_size());

  external_top_ = Utils::address_at(external_top_, Utils::round_up(sizeof(Program), WORD_SIZE));

  int offset = Utils::round_up(reinterpret_cast<uword>(external_end), TOIT_PAGE_SIZE) - reinterpret_cast<uword>(external_end);
  block_top_ = Utils::address_at(external_end, offset);
  ASSERT(Utils::is_aligned((uword)block_top_, TOIT_PAGE_SIZE));
  return true;
}

ProgramImage ImageSnapshotReader::read_image(const uint8* id) {
  // Also calls SnapshotReader::initialize() which calls allocator_->initialize().
  // allocator_ is an ImageAllocator
  //   which is a subclass of HeapAllocator
  //     which is a subset of SnapshotAllocator
  bool succeeded = read_header();
  ASSERT(succeeded);  // We expect to never run out of memory on the desktop.
  program_  = new (image_allocator_.memory()) Program(image_allocator_.image()->address(), image_allocator_.image()->byte_size());
  image_allocator_.set_program(program_);
  // Initialize the uuid to 0. It can be patched from the outside.
  uint8 uuid[UUID_SIZE] = {0};
  program_->set_header(0, uuid, id);

  image_allocator_.expand();
  program_->read(this);
  image_allocator_.image()->mark_read_only();

  return ProgramImage(image_allocator_.image());
}

void ImageAllocator::expand() {
  ProgramBlock* block = new (block_top_) ProgramBlock();
  block_top_ = Utils::address_at(block_top_, TOIT_PAGE_SIZE);
  program_->heap_.blocks_.append(block);
}

HeapObject* ImageAllocator::allocate_object(TypeTag tag, int length) {
  int word_count, extra_bytes;
  allocation_size(tag, length, &word_count, &extra_bytes);
  int byte_size = _align(word_count * sizeof(word) + extra_bytes);
  HeapObject* result = program_->heap_.blocks_.last()->allocate_raw(byte_size);
  if (result != null) return result;
  ASSERT(byte_size < ProgramHeap::max_allocation_size());
  expand();
  return program_->heap_.blocks_.last()->allocate_raw(byte_size);
}

void* ImageAllocator::allocate_external(int byte_size) {
  void* result = external_top_;
  external_top_ = Utils::address_at(external_top_, Utils::round_up(byte_size, WORD_SIZE));
  return result;
}

SnapshotGenerator::~SnapshotGenerator() {
  free(buffer_);
}

int SnapshotGenerator::large_integer_class_id() {
  return program_->large_integer_class_id()->value();
}

void SnapshotGenerator::generate(Program* program) {
  generate(PROGRAM_SNAPSHOT_HEADER_BYTE_SIZE,
           [&](EmittingSnapshotWriter* writer) { writer->write_program_snapshot_header(); },
           [&](SnapshotWriter* writer) { program->write(writer); });
}

void SnapshotGenerator::generate(int header_byte_size,
                                 std::function<void (EmittingSnapshotWriter*)> write_header,
                                 std::function<void (SnapshotWriter*)> write_object) {
  CollectingSnapshotWriter collector(large_integer_class_id(), program_);
  collector.reserve_header(header_byte_size);
  write_object(&collector);

  length_ = collector.length();
  buffer_ = unvoid_cast<uint8*>(malloc(length_));
  EmittingSnapshotWriter emitter(buffer_,
                                 length_,
                                 collector.back_reference_targets(),
                                 large_integer_class_id(),
                                 program_);
  emitter.reserve_header(header_byte_size);
  write_object(&emitter);
  write_header(&emitter);

  // We might have allocated too much memory, as we didn't know the size of
  //   the back references.
  if (emitter.remaining() != 0) {
    length_ = length_ - emitter.remaining();
    buffer_ = unvoid_cast<uint8*>(realloc(buffer_, length_));
  }
}

uint8* SnapshotGenerator::take_buffer(int* length) {
  *length = length_;
  auto result = buffer_;
  buffer_ = null;
  length_ = 0;
  return result;
}

void CollectingSnapshotWriter::reserve_header(int header_byte_size) {
  length_ += header_byte_size;
}
void CollectingSnapshotWriter::write_byte(uint8 value) {
  length_ += 1;
}
void CollectingSnapshotWriter::write_bytes(uint8* data, int length) {
  length_ += length;
}

bool CollectingSnapshotWriter::is_back_reference(uword object_key, int* back_reference_id) {
  auto probe = seen_.find(object_key);
  if (probe == seen_.end()) {
    seen_.insert(object_key);
    *back_reference_id = -1;
    return false;
  }
  back_reference_targets_.insert(object_key);
  // For simplicity just return the current object count.
  // The back reference id is almost certainly lower, but this way we make sure
  //   to have enough space.
  *back_reference_id = seen_.size();
  return true;
}

bool CollectingSnapshotWriter::is_back_reference_target(uword object_key) {
  // In the collecting writer we don't have enough information. (That's the purpose
  //   of the collecting pass).
  // Simply return false.
  return false;
}

void EmittingSnapshotWriter::reserve_header(int header_byte_size) {
  int amount = header_byte_size;
  ASSERT(pos_ + amount <= length_);
  pos_ += amount;
}

void EmittingSnapshotWriter::write_byte(uint8 value) {
  ASSERT(pos_ + 1 <= length_);
  buffer_[pos_++] = value;
}
void EmittingSnapshotWriter::write_bytes(uint8* data, int length) {
  ASSERT(pos_ + length <= length_);
  memcpy(&buffer_[pos_], data, length);
  pos_ += length;
}

bool EmittingSnapshotWriter::is_back_reference(uword object_key, int* back_reference_id) {
  auto probe = back_reference_mapping_.find(object_key);
  if (probe == back_reference_mapping_.end()) {
    *back_reference_id = -1;
    return false;
  }
  *back_reference_id = probe->second;
  return true;
}

bool EmittingSnapshotWriter::is_back_reference_target(uword object_key) {
  ASSERT(back_reference_mapping_.find(object_key) == back_reference_mapping_.end());
  auto probe = back_reference_targets_.find(object_key);
  if (probe == back_reference_targets_.end()) return false;
  back_reference_mapping_.emplace(object_key, back_reference_index_++);
  return true;
}

void BaseSnapshotWriter::write_cardinal(uword value) {
  while (value >= 128) {
    write_byte((uint8) (value % 128 + 128));
    value >>= 7;
  }
  write_byte((uint8) value);
}

void BaseSnapshotWriter::write_cardinal64(uint64 value) {
  while (value >= 128) {
    write_byte((uint8) (value % 128 + 128));
    value >>= 7;
  }
  write_byte((uint8) value);
}

void BaseSnapshotWriter::write_integer(int64 value) {
  if (value >= 0) {
    write_object_header(SnapshotTypeTag::POSITIVE_SMI_TAG);
    write_cardinal64(value);
  } else {
    write_object_header(SnapshotTypeTag::NEGATIVE_SMI_TAG);
    // In the case of INT64_MIN the value of `-value` will still be negative, but
    // the implicit cast to uint64 (the parameter type of [write_cardinal64])
    // converts to a positive number.
    // Converting from signed to unsigned integer (of same size) with two's
    // complement representation does not change the bit-pattern.
    write_cardinal64(-value);
  }
  if (!Smi::is_valid32(value)) {
    // No need to allocate any object if it's a valid 32-bit smi.
    allocator_.allocate_integer(value);
  }
}

int EmittingSnapshotWriter::write_uint32_at(int byte_offset, uint32 value) {
  static_assert(sizeof(value) == 4, "Unexpected type size");
  uint8 bytes[4];
  memcpy(&bytes, &value, sizeof(value));
  for (int i = 0; i < 4; i++) {
    buffer_[byte_offset + i] = bytes[i];
  }
  return byte_offset + UINT32_SIZE;
}

void EmittingSnapshotWriter::write_program_snapshot_header() {
  int offset = 0;
  offset = write_uint32_at(offset, PROGRAM_SNAPSHOT_MAGIC);
  offset = write_uint32_at(offset, pos_);
  int block_count32 = allocator_.normal_block_count(4);
  int block_count64 = allocator_.normal_block_count(8);
  int encoded_block_count = (block_count32 << 16) + block_count64;
  offset = write_uint32_at(offset, encoded_block_count);
  // Use the 64-bit values for the external entries, as they have more alignment.
  // We could encode them separately, but we wouldn't win a lot.
  offset = write_uint32_at(offset, allocator_.external_pointer_count(64));
  offset = write_uint32_at(offset, allocator_.external_int32_count(64));
  offset = write_uint32_at(offset, allocator_.external_byte_count(64));
  int object_table_length = back_reference_index_;
  offset = write_uint32_at(offset, object_table_length);
  offset = write_uint32_at(offset, large_integer_class_id());
  ASSERT(offset == PROGRAM_SNAPSHOT_HEADER_BYTE_SIZE);
}

void BaseSnapshotWriter::write_double(double value) {
  static_assert(sizeof(value) == 8, "Unexpected type size");
  uint8 bytes[8];
  memcpy(&bytes, &value, sizeof(value));
  for (int i = 0; i < 8; i++) write_byte(bytes[i]);
}

void BaseSnapshotWriter::write_int32(int32 value) {
  static_assert(sizeof(value) == 4, "Unexpected type size");
  uint8 bytes[4];
  memcpy(&bytes, &value, sizeof(value));
  for (int i = 0; i < 4; i++) write_byte(bytes[i]);
}

void BaseSnapshotWriter::write_uint16(uint16 value) {
  static_assert(sizeof(value) == 2, "Unexpected type size");
  uint8 bytes[2];
  memcpy(&bytes, &value, sizeof(value));
  for (int i = 0; i < 2; i++) write_byte(bytes[i]);
}

void BaseSnapshotWriter::write_uint64(uint64 value) {
  static_assert(sizeof(value) == 8, "Unexpected type size");
  uint8 bytes[8];
  memcpy(&bytes, &value, sizeof(value));
  for (int i = 0; i < 8; i++) write_byte(bytes[i]);
}

void BaseSnapshotWriter::write_reference(int index) {
  write_object_header(SnapshotTypeTag::BACK_REFERENCE_TAG, index);
}

void BaseSnapshotWriter::write_object(Object* object) {
  if (is_smi(object)) write_integer(Smi::cast(object)->value());
  else if (is_large_integer(object)) write_integer(LargeInteger::cast(object)->value());
  else write_heap_object(HeapObject::cast(object));
}

void BaseSnapshotWriter::write_external_object_table(Object** table, int length) {
  ASSERT(length >= 0);
  write_cardinal(length);
  for (int i = 0; i < length; i++) {
    write_object(table[i]);
  }
  allocator_.allocate_external_pointers(length);
}

void BaseSnapshotWriter::write_external_list_int32(List<int32> list) {
  write_int32(list.length());
  for (int i = 0; i < list.length(); i++) {
    // Use `write_int32` to make sure endianness is not an issue.
    write_int32(list[i]);
  }
  allocator_.allocate_external_int32s(list.length());
}

void BaseSnapshotWriter::write_external_list_uint16(List<uint16> list) {
  write_int32(list.length());
  for (int i = 0; i < list.length(); i++) {
    // Use `write_uint16` to make sure endianness is not an issue.
    write_uint16(list[i]);
  }
  allocator_.allocate_external_uint16s(list.length());
}

void BaseSnapshotWriter::write_external_list_uint8(List<uint8> list) {
  write_int32(list.length());
  write_bytes(list.data(), list.length());
  allocator_.allocate_external_bytes(list.length());
}

static int optional_length(HeapObject* object, Program* program) {
  switch (object->class_tag()) {
  case TypeTag::ARRAY_TAG: return Array::cast(object)->length();
  case TypeTag::BYTE_ARRAY_TAG: return ByteArray::Bytes(ByteArray::cast(object)).length();
  case TypeTag::STRING_TAG: return String::cast(object)->length();
  case TypeTag::INSTANCE_TAG: return Instance::fields_from_size(program->instance_size_for(object));
  default:
    return 0;
  }
}

void BaseSnapshotWriter::write_heap_object(HeapObject* object) {
  uword key = object->_raw();
  int back_reference_index;
  if (is_back_reference(key, &back_reference_index)) {
    write_reference(back_reference_index);
    return;
  }
  bool is_target = is_back_reference_target(key);
  TypeTag tag = object->class_tag();
  int length = optional_length(object, program_);
  write_object_header(is_target ? SnapshotTypeTag::IN_TABLE_TAG : SnapshotTypeTag::OBJECT_TAG,
                      length);
  write_byte(tag);
  allocator_.allocate_object(tag, length);
  ASSERT(is_smi(object->header()));
  write_object(object->header());
  switch (object->class_tag()) {
    case TypeTag::ARRAY_TAG:
      Array::cast(object)->write_content(this);
      break;
    case TypeTag::BYTE_ARRAY_TAG:
      ByteArray::cast(object)->write_content(this);
      break;
    case TypeTag::STRING_TAG:
      String::cast(object)->write_content(this);
      break;
    case TypeTag::ODDBALL_TAG:
      // Oddballs have no body parts.
      break;
    case TypeTag::INSTANCE_TAG:
      Instance::cast(object)->write_content(program_->instance_size_for(object), this);
      break;
    case TypeTag::DOUBLE_TAG:
      Double::cast(object)->write_content(this);
      break;
    case TypeTag::LARGE_INTEGER_TAG:
      FATAL("Should never write large integer object to snapshot");
    default:
      FATAL("Unexpected class tag");
  }
}

#endif  // TOIT_FREERTOS

void PointerCallback::object_table(Object** table, int length) {
  ASSERT(length >= 0);
  for (int i = 0; i < length; i++) object_address(&table[i]);
}

void ProgramImage::do_pointers(PointerCallback* callback) const {
  program()->do_pointers(callback);
}

#ifndef TOIT_FREERTOS

class RelocationBits : public PointerCallback {
 public:
  RelocationBits(const ProgramImage& image)
      : relocation_bits_(_new word[image.byte_size() / PAYLOAD_SIZE])
  , image_(image) {
    ASSERT(image.byte_size() % PAYLOAD_SIZE == 0);
    memset(relocation_bits_, 0, WORD_SIZE * (image.byte_size() / PAYLOAD_SIZE));
  }

  bool get_bit_for(word* addr) {
    int word_index = word_index_for(addr);
    int bit_number = bit_number_for(addr);
    return (relocation_bits_[word_index] >> bit_number) & 1U;
  }

  word get_bits_for_payload(int n) {
    return relocation_bits_[n];
  }

 public:
  void object_address(Object** p) {
    // Only make heap objects relocatable.
    if (is_heap_object(*p)) set_bit_for(reinterpret_cast<word*>(p));
  }

  void c_address(void** p, bool is_sentinel) {
    // Only make non null pointers relocatable.
    if (*p != null) {
      word* value = (word*) *p;
      ASSERT(image_.address_inside(value) ||
             (is_sentinel && value == image_.address()) + image_.byte_size());
      set_bit_for(reinterpret_cast<word*>(p));
    }
  }

 private:
  static const int PAYLOAD_SIZE = WORD_BIT_SIZE * WORD_SIZE;

  word* relocation_bits_;
  ProgramImage image_;

  void set_bit_for(word* addr) {
    int word_index = word_index_for(addr);
    int bit_number = bit_number_for(addr);
    relocation_bits_[word_index] |= 1UL << bit_number;
    ASSERT(get_bit_for(addr));
  }

  int word_index_for(word* addr) {
    return distance_to(addr) / PAYLOAD_SIZE;
  }

  int bit_number_for(word* addr) {
    int result = (distance_to(addr) % PAYLOAD_SIZE) / WORD_SIZE;
    ASSERT(result >= 0 && result < WORD_BIT_SIZE);
    return result;
  }

  word distance_to(word* addr) {
    ASSERT(image_.address_inside(addr));
    return Utils::address_distance(image_.begin(), addr);
  }
};

RelocationBits* ImageInputStream::build_relocation_bits(const ProgramImage& image) {
  RelocationBits* result = _new RelocationBits(image);
  image.do_pointers(result);
  return result;
}

ImageInputStream::ImageInputStream(const ProgramImage& image,
                                   RelocationBits* relocation_bits)
    : image_(image)
    , relocation_bits(relocation_bits)
    , current(image.begin())
    , index(0) {}

int ImageInputStream::words_to_read() {
  ASSERT(!eos());
  int ready_words = Utils::address_distance(current, image_.end()) / WORD_SIZE;
  return Utils::min(ImageOutputStream::CHUNK_SIZE, 1 + ready_words);
}

int ImageInputStream::read(word* buffer) {
  ASSERT(!eos());
  int pos = 1;
  while (pos <= WORD_BIT_SIZE && (current < image_.end())) {
    word value = *current;
    if (relocation_bits->get_bit_for(current)) {
      value = Utils::address_distance(image_.begin(), reinterpret_cast<word*>(value));
      // Sentinels may point to `image_.end()`.
      ASSERT(value <= (word) Utils::address_distance(image_.begin(), image_.end()));
    }
    current = Utils::address_at(current, WORD_SIZE);
    buffer[pos++] = value;
  }
  buffer[0] = relocation_bits->get_bits_for_payload(index++);
  return pos;
}

#endif  // TOIT_FREERTOS

ImageOutputStream::ImageOutputStream(ProgramImage image)
    : image_(image)
    , current_(image.begin()) {
  memset(program_id_, 0, sizeof(program_id_));
}

void ImageOutputStream::write(const word* buffer, int size, word* output) {
  ASSERT(1 < size && size <= CHUNK_SIZE);
  if (output == null) output = current_;
  // The input buffer is often part of network packets with various headers,
  // so the embedded words aren't guaranteed to be word-aligned.
  word mask = Utils::read_unaligned_word(&buffer[0]);
  for (int index = 1; index < size; index++) {
    word value = Utils::read_unaligned_word(&buffer[index]);
    // Relocate value if needed with the address of the image.
    if (mask & 1U) value += reinterpret_cast<word>(image_.begin());
    mask = mask >> 1;
    output[index - 1] = value;
    current_++;
  }
}

void ImageOutputStream::set_program_id(const uint8* id) {
  memmove(program_id_, id, sizeof(program_id_));
}

}  // namespace toit

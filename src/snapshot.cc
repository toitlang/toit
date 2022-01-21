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
#include "heap.h"
#include "os.h"
#include "uuid.h"
#include "vm.h"

namespace toit {

#ifndef TOIT_FREERTOS

enum class SnapshotTypeTag {
  OBJECT_TAG = 0,
  IN_TABLE_TAG,
  BACK_REFERENCE_TAG,
  PROGRAM_HEAP_REFERENCE_TAG,
  POSITIVE_SMI_TAG,
  NEGATIVE_SMI_TAG,  // Last element must be tested in static_assert below.
};
static const int OBJECT_HEADER_TYPE_SIZE = 3;
static_assert(static_cast<int>(SnapshotTypeTag::NEGATIVE_SMI_TAG) < (1 << OBJECT_HEADER_TYPE_SIZE),
              "Invalid object header width");
static const int OBJECT_HEADER_TYPE_MASK = (1 << OBJECT_HEADER_TYPE_SIZE) - 1;

static const uint32 PROGRAM_SNAPSHOT_MAGIC = 70177017;  // Toit toit.

static const int PROGRAM_SNAPSHOT_HEADER_BYTE_SIZE = 8 * UINT32_SIZE;
static const int OBJECT_SNAPSHOT_HEADER_BYTE_SIZE = 5 * UINT32_SIZE;

namespace {

template <typename V>
class Node {
 public:
  Node(uword key, const V& value) : key(key), value(value), left(null), right(null) { }
  uword key;
  V value;
  Node<V>* left;
  Node<V>* right;
};

template <typename V>
class BinaryTree {
 public:
  BinaryTree() : ref_count(_new int(1)) { }
  BinaryTree(const BinaryTree& other)
      : ref_count(other.ref_count)
      , _size(other._size)
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
    _size = other._size;
    root = other.root;
    return *this;
  }

  void insert(uword key, const V& value) {
    ASSERT((*ref_count) == 1);
    // Mangle the key to give a more uniform distribution.
    key = hash(key);
    if (root == null) {
      _size++;
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
          _size++;
          current->left = _new Node<V>(key, value);
          return;
        }
        current = current->left;
        continue;
      }
      ASSERT(key > current->key);
      if (current->right == null) {
        _size++;
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

  int size() const { return _size; }

 private:
  int* ref_count;
  int _size = 0;
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

/// An allocator that uses the current host's word
/// size and aligns everything to its natural alignment.
/// All allocations are lowered to byte allocations and
/// fed to pure virtual allocate(int), which is assumed
/// to update _byte_count.
class HeapAllocator : public SnapshotAllocator {
 public:
  bool initialize(int pointer_count,
                  int byte_count) {
    _pointer_count = pointer_count;
    _byte_count = byte_count;
    return true;
  }

  uint8* allocate_bytes(int count) {
    return unvoid_cast<uint8*>(allocate(count));
  }

  void skip_bytes(int count) override {
    allocate_bytes(count);
  }

  Object** allocate_pointers(int count) {
    round_bytes(sizeof(Object*));
    _pointer_count += count
    return unvoid_cast<Object**>(allocate(count * sizeof(Object*)));
  }

  uint16* allocate_uint16s(int count) {
    round_bytes(2);
    return unvoid_cast<uint16*>(allocate(count * 2));
  }

  int32* allocate_int32s(int count) {
    round_bytes(4);
    return unvoid_cast<int32*>(allocate(count * 4));
  }

  int pointer_count() const { return _pointer_count; }
  int byte_count() const override { return _byte_count; }

 protected:
  virtual void* allocate(int byte_size) = 0;

 private:
  int _pointer_count;
  int _byte_count;
};

/// A virtual allocator with a given word size.
/// The allocator mimics the heap allocations in the ImageAllocator for the
/// given platform, and is used to determine how much memory should be used
/// for a program when it's deserialized.
class SizedVirtualAllocator : public AligningAllocator {
 public:
  SizedVirtualAllocator(int word_size)
      : _word_size(word_size) { }

  HeapObject* allocate_object(TypeTag tag, int length);

  void allocate_integer(int64 value) {
    if ((_word_size == 4 && Smi::is_valid32(value)) ||
        (_word_size == 8 && Smi::is_valid64(value))) {
      return;
    }
    allocate_object(TypeTag::LARGE_INTEGER_TAG, 0);
  }

  void allocate_pointers(int count) {
    round_bytes(_word_size);
    _pointer_count += count;
  }

  void allocate_int32s(int count) {
    round_bytes(4);
    _byte_count += count * 4;
  }

  void allocate_uint16s(int count) {
    round_bytes(2);
    _byte_count += count * 2;
  }

  void allocate_bytes(int count) {
    _byte_count += count;
  }

  void skip_bytes(int count) override {
    allocate_bytes(count);
  }

  int pointer_count() const {  return _pointer_count; }
  int byte_count() const override {  return _byte_count; }

 private:
  int _word_size;
  int top = 0;
  int _pointer_count = 0;
  int _byte_count = 0;
};

class VirtualAllocator : public SnapshotAllocator {
 public:
  VirtualAllocator()
      : _allocator32(4)
      , _allocator64(8) { }

  bool initialize(int pointer_count,
                  int byte_count) {
    // We are using the virtual allocator to find these values.
    UNREACHABLE();
    return true;
  }

  void skip_bytes(int count) override {
    UNREACHABLE();
  }

  int byte_count() const override {
    UNREACHABLE();
  }

  int byte_count_32_bit() const {
    return _allocator32.byte_count();
  }

  int byte_count_64_bit() const {
    return _allocator64.byte_count();
  }

  int pointer_count() const {
    ASSERT(_allocator32.pointer_count() == _allocator64.pointer_count());
    return _allocator64.pointer_count();
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

  Object** allocate_pointers(int count) {
    _allocator32.allocate_pointers(count);
    _allocator64.allocate_pointers(count);
    return null;
  }

  int32* allocate_int32s(int count) {
    _allocator32.allocate_int32s(count);
    _allocator64.allocate_int32s(count);
    return null;
  }

  uint16* allocate_uint16s(int count) {
    _allocator32.allocate_uint16s(count);
    _allocator64.allocate_uint16s(count);
    return null;
  }

  uint8* allocate_bytes(int count) {
    _allocator32.allocate_bytes(count);
    _allocator64.allocate_bytes(count);
    return null;
  }

  int pointer_count(int word_size) const {
    return word_size == 4
        ? _allocator32.pointer_count()
        : _allocator64.pointer_count();
  }
  int byte_count(int word_size) const {
    return word_size == 4
        ? _allocator32.byte_count()
        : _allocator64.byte_count();
  }

 private:
  SizedVirtualAllocator _allocator32;
  SizedVirtualAllocator _allocator64;
};

}  // Anonymous namespace.

class ImageAllocator : public HeapAllocator {
 public:
  bool initialize(int pointer_count, int byte_count);

  HeapObject* allocate_object(TypeTag tag, int length);

  ProtectableAlignedMemory* image() const { return _image; }

  void* memory() const { return _memory; }

  void set_program(Program* program) { _program = program; }

  void expand();

 protected:
  void* allocate(int byte_size);

 private:
  ProtectableAlignedMemory* _image = null;
  void* _memory = null;
  void* _top = null;

  Program* _program = null;

  // Returns the byte_size needed for the unfolded page aligned image.
  uword image_byte_size();
};

template <typename T>
using WorkAroundSet = BinaryTreeSet;

template <typename K, typename V>
using WorkAroundMap = BinaryTreeMap<V>;

class ImageSnapshotReader : public SnapshotReader {
 public:
  ImageSnapshotReader(const uint8* buffer, int length)
    : SnapshotReader(buffer, length, &_image_allocator) { }

  // Reads the snapshot.
  ProgramImage read_image();

 protected:
  bool read_header();
  HeapObject* read_program_heap_reference(uword offset);

 private:
  ImageAllocator _image_allocator;
  Program* _program = null;
};

class BaseSnapshotWriter : public SnapshotWriter {
 public:
  BaseSnapshotWriter(int large_integer_class_id,
                     Program* program)
      : _large_integer_class_id(large_integer_class_id)
      , _program(program) { }

  void write_byte(uint8 value) = 0;
  void write_cardinal(uword value);
  void write_double(double value);
  void write_object(Object* object);
  void write_external_object_table(Object** table, int length);
  void write_list_int32(List<int32> list);
  void write_list_uint16(List<uint16> list);
  void write_list_uint8(List<uint8> list);

 protected:
  VirtualAllocator _allocator;

  virtual void write_bytes(uint8* data, int length) = 0;

  /// Whether the object with the given key is a back reference.
  /// Fills the back_reference_id if the object is a back reference.
  virtual bool is_back_reference(uword object_key, int* back_reference_id) = 0;
  /// Whether the object with the given key will be the target of a
  ///   back reference.
  /// The result of this call does not change the size of the generated snapshot.
  virtual bool is_back_reference_target(uword object_key) = 0;

  int large_integer_class_id() const { return _large_integer_class_id; }

 private:
  int const _large_integer_class_id;

  Program* _program;

  bool is_program_heap_reference(HeapObject* object, uword* offset);

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

  int length() const { return _length; }
  const WorkAroundSet<uword>& back_reference_targets() const { return _back_reference_targets; }

 protected:
  void write_bytes(uint8* data, int length);

  bool is_back_reference(uword object_key, int* back_reference_id);
  bool is_back_reference_target(uword object_key);

 private:
  int _length = 0;
  WorkAroundSet<uword> _seen;
  WorkAroundSet<uword> _back_reference_targets;
};

class EmittingSnapshotWriter : public BaseSnapshotWriter {
 public:
  EmittingSnapshotWriter(uint8* buffer,
                         int length,
                         const WorkAroundSet<uword>& back_reference_targets,
                         int large_integer_class_id,
                         Program* program)
      : BaseSnapshotWriter(large_integer_class_id, program)
      , _buffer(buffer)
      , _length(length)
      , _back_reference_targets(back_reference_targets) { }

  void write_byte(uint8 value);

  void reserve_header(int header_byte_size);

  // Must be called last, since it uses the data that was accumulated by the
  //   virtual allocator.
  void write_program_snapshot_header();
  // Must be called last, since it uses the data that was accumulated by the
  //   virtual allocator.
  void write_object_snapshot_header();

  int remaining() const { return _length - _pos; }

 protected:
  void write_bytes(uint8* data, int length);

  bool is_back_reference(uword object_key, int* back_reference_id);
  bool is_back_reference_target(uword object_key);

 private:
  uint8* const _buffer;
  int const _length;
  WorkAroundSet<uword> const _back_reference_targets;
  WorkAroundMap<uword, int> _back_reference_mapping;
  int _pos = 0;
  int _back_reference_index = 0;

  /// Returns the new offset.
  int write_uint32_at(int byte_offset, uint32 value);
};

ImageAllocator::allocate(int size) {

}

ProgramImage Snapshot::read_image() {
  ImageSnapshotReader reader(_buffer, _size);
  return reader.read_image();
}

SnapshotReader::SnapshotReader(const uint8* buffer, int length, SnapshotAllocator* allocator)
    : _buffer(buffer)
    , _length(length)
    , _allocator(allocator)
    , _large_integer_id(-1)
    , _snapshot_size(0)
    , _index(0)
    , _pos(0)
    , _table(null) { }

SnapshotReader::~SnapshotReader() {
  delete[] _table;
}

bool SnapshotReader::initialize(int snapshot_size,
                                int pointer_count,
                                int byte_count,
                                int table_length,
                                int large_integer_id) {
  _snapshot_size = snapshot_size;
  bool succeeded = _allocator->initialize(pointer_count,
                                          byte_count);
  if (!succeeded) return false;
  _table_length = table_length;
  _table = _new HeapObject*[_table_length];
  _large_integer_id = large_integer_id;
  return _table != null;
}

HeapObject* SnapshotReader::allocate_object(TypeTag tag, int length) {
  return _allocator->allocate_object(tag, length);
}
Object** SnapshotReader::allocate_pointers(int count) {
  return _allocator->allocate_pointers(count);
}
uint16* SnapshotReader::allocate_uint16s(int count) {
  return _allocator->allocate_uint16s(count);
}
int32* SnapshotReader::allocate_int32s(int count) {
  return _allocator->allocate_int32s(count);
}
uint8* SnapshotReader::allocate_bytes(int count) {
  return _allocator->allocate_bytes(count);
}

// Returns object table length.
bool ImageSnapshotReader::read_header() {
  uint32 magic = read_uint32();
  if (magic != PROGRAM_SNAPSHOT_MAGIC) {
    printf("Magic marker in snapshot is %x!\n", magic);
    exit(1);
  }
  int snapshot_size = read_uint32();
  int pointer_count = read_uint32();
  int byte_count = read_uint32();
  int table_length = read_uint32();
  int large_integer_id = read_uint32();
  return initialize(snapshot_size,
                    pointer_count,
                    byte_count,
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
  ASSERT(_pos < _length);
  return _buffer[_pos++];
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
  auto large_integer_class_bits = _class_bits[_large_integer_id];
  TypeTag class_tag = Program::class_tag_from_class_bits(large_integer_class_bits);
  LargeInteger* result = static_cast<LargeInteger*>(allocate_object(TypeTag::LARGE_INTEGER_TAG, 0));
  result->_set_header(Smi::from(_large_integer_id), class_tag);
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

HeapObject* ImageSnapshotReader::read_program_heap_reference(uword offset) {
  FATAL("Reading program heap reference in image snapshot reader.");
}

Object* SnapshotReader::read_object() {
  SnapshotTypeTag type;
  int extra;
  read_object_header(&type, &extra);
  switch (type) {
    case SnapshotTypeTag::POSITIVE_SMI_TAG: return read_integer(false);
    case SnapshotTypeTag::NEGATIVE_SMI_TAG: return read_integer(true);
    case SnapshotTypeTag::BACK_REFERENCE_TAG: return _table[extra];
    case SnapshotTypeTag::PROGRAM_HEAP_REFERENCE_TAG: return read_program_heap_reference(extra);
    case SnapshotTypeTag::OBJECT_TAG:
    case SnapshotTypeTag::IN_TABLE_TAG:
      // Handled here.
      break;
  }
  bool in_table = type == SnapshotTypeTag::IN_TABLE_TAG;
  int optional_length = extra;
  TypeTag heap_tag = (TypeTag) (read_byte());
  HeapObject* result = allocate_object(heap_tag, optional_length);
  if (in_table) _table[_index++] = result;
  result->_set_header(Smi::cast(read_object()));
  ASSERT((0 <= result->class_id()->value() && result->class_id()->value() < _class_bits_length));
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
  int32* data = allocate_int32s(length);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(data), WORD_SIZE));
  List<int32> result(data, length);
  for (int i = 0; i < length; i++) {
    result[i] = read_int32();
  }
  return result;
}

List<uint16> SnapshotReader::read_external_list_uint16() {
  int length = read_int32();
  uint16* data = allocate_uint16s(length);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(data), WORD_SIZE));
  List<uint16> result(data, length);
  for (int i = 0; i < length; i++) {
    result[i] = read_uint16();
  }
  return result;
}

List<uint8> SnapshotReader::read_external_list_uint8() {
  int length = read_int32();
  uint8* data = allocate_bytes(length);
  ASSERT(Utils::is_aligned(reinterpret_cast<uword>(data), WORD_SIZE));
  memcpy(data, &_buffer[_pos], length);
  _pos += length;
  return List<uint8>(data, length);
}

Object** SnapshotReader::read_external_object_table(int* length) {
  int n = read_cardinal();
  Object** table = allocate_pointers(n);
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
  int byte_size = _align(word_count * _word_size + extra_bytes, _word_size);
  ASSERT(byte_size > 0 && Utils::is_aligned(byte_size, _word_size));
  top += byte_size;
  return null;
}

bool ImageAllocator::initialize(
                  int pointer_count,
                  int byte_count) {
  HeapAllocator::initialize(pointer_count, byte_count);

  int memory_byte_size = image_byte_size();
  _image = _new ProtectableAlignedMemory(memory_byte_size, TOIT_PAGE_SIZE);
  _memory = _image->address();

#ifndef DEBUG
  // Keep the uninitialized 0xcd markers in debug mode, but otherwise
  // initialize the memory to 0 to make the image more deterministic.
  memset(_memory, 0, memory_byte_size);
#endif
  _top = _memory;
  return true;
}

ProgramImage ImageSnapshotReader::read_image() {
  bool succeeded = read_header();
  ASSERT(succeeded);  // We expect to never run out of memory on the desktop.
  _program  = new (_image_allocator.memory()) Program();
  _image_allocator.set_program(_program);
  // Initialize the uuid to 0. It can be patched from the outside.
  uint8 uuid[UUID_SIZE] = {0};
  _program->set_header(0, uuid);
  _program->read(this);
  _image_allocator.image()->mark_read_only();

  return ProgramImage(_image_allocator.image());
}

HeapObject* ImageAllocator::allocate_object(TypeTag tag, int length) {
  int word_count, extra_bytes;
  allocation_size(tag, length, &word_count, &extra_bytes);
  HeapObject* result = _program->_heap->allocate_pointers(word_count);
  // Immediately allocate the extra bytes so they are immediately after the
  // pointer part of the object.  All objects have this layout, and on the
  // program heap this even applies to external byte arrays and strings.
  _program->_heap->allocate_bytes(extra_bytes);
  return result;
}

SnapshotGenerator::~SnapshotGenerator() {
  free(_buffer);
}

int SnapshotGenerator::large_integer_class_id() {
  return _program->large_integer_class_id()->value();
}

void SnapshotGenerator::generate(Program* program) {
  generate(PROGRAM_SNAPSHOT_HEADER_BYTE_SIZE,
           [&](EmittingSnapshotWriter* writer) { writer->write_program_snapshot_header(); },
           [&](SnapshotWriter* writer) { program->write(writer); });
}

void SnapshotGenerator::generate(int header_byte_size,
                                 std::function<void (EmittingSnapshotWriter*)> write_header,
                                 std::function<void (SnapshotWriter*)> write_program) {
  CollectingSnapshotWriter collector(large_integer_class_id(), _program);
  collector.reserve_header(header_byte_size);
  write_program(&collector);

  _length = collector.length();
  _buffer = unvoid_cast<uint8*>(malloc(_length));
  EmittingSnapshotWriter emitter(_buffer,
                                 _length,
                                 collector.back_reference_targets(),
                                 large_integer_class_id(),
                                 _program);
  emitter.reserve_header(header_byte_size);
  write_program(&emitter);
  write_header(&emitter);

  // We might have allocated too much memory, as we didn't know the size of
  //   the back references.
  if (emitter.remaining() != 0) {
    _length = _length - emitter.remaining();
    _buffer = unvoid_cast<uint8*>(realloc(_buffer, _length));
  }
}

uint8* SnapshotGenerator::take_buffer(int* length) {
  *length = _length;
  auto result = _buffer;
  _buffer = null;
  _length = 0;
  return result;
}

void CollectingSnapshotWriter::reserve_header(int header_byte_size) {
  _length += header_byte_size;
}
void CollectingSnapshotWriter::write_byte(uint8 value) {
  _length += 1;
}
void CollectingSnapshotWriter::write_bytes(uint8* data, int length) {
  _length += length;
}

bool CollectingSnapshotWriter::is_back_reference(uword object_key, int* back_reference_id) {
  auto probe = _seen.find(object_key);
  if (probe == _seen.end()) {
    _seen.insert(object_key);
    *back_reference_id = -1;
    return false;
  }
  _back_reference_targets.insert(object_key);
  // For simplicity just return the current object count.
  // The back reference id is almost certainly lower, but this way we make sure
  //   to have enough space.
  *back_reference_id = _seen.size();
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
  ASSERT(_pos + amount <= _length);
  _pos += amount;
}

void EmittingSnapshotWriter::write_byte(uint8 value) {
  ASSERT(_pos + 1 <= _length);
  _buffer[_pos++] = value;
}
void EmittingSnapshotWriter::write_bytes(uint8* data, int length) {
  ASSERT(_pos + length <= _length);
  memcpy(&_buffer[_pos], data, length);
  _pos += length;
}

bool EmittingSnapshotWriter::is_back_reference(uword object_key, int* back_reference_id) {
  auto probe = _back_reference_mapping.find(object_key);
  if (probe == _back_reference_mapping.end()) {
    *back_reference_id = -1;
    return false;
  }
  *back_reference_id = probe->second;
  return true;
}

bool EmittingSnapshotWriter::is_back_reference_target(uword object_key) {
  ASSERT(_back_reference_mapping.find(object_key) == _back_reference_mapping.end());
  auto probe = _back_reference_targets.find(object_key);
  if (probe == _back_reference_targets.end()) return false;
  _back_reference_mapping.emplace(object_key, _back_reference_index++);
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
    _allocator.allocate_integer(value);
  }
}

int EmittingSnapshotWriter::write_uint32_at(int byte_offset, uint32 value) {
  static_assert(sizeof(value) == 4, "Unexpected type size");
  uint8 bytes[4];
  memcpy(&bytes, &value, sizeof(value));
  for (int i = 0; i < 4; i++) {
    _buffer[byte_offset + i] = bytes[i];
  }
  return byte_offset + UINT32_SIZE;
}

void EmittingSnapshotWriter::write_program_snapshot_header() {
  int offset = 0;
  offset = write_uint32_at(offset, PROGRAM_SNAPSHOT_MAGIC);
  offset = write_uint32_at(offset, _pos);
  offset = write_uint32_at(offset, _allocator.byte_count_32_bit() + 4 * _allocator.pointer_count());
  offset = write_uint32_at(offset, _allocator.byte_count_64_bit() + 8 * _allocator.pointer_count());
  int object_table_length = _back_reference_index;
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
  if (object->is_smi()) write_integer(Smi::cast(object)->value());
  else if (object->is_large_integer()) write_integer(LargeInteger::cast(object)->value());
  else write_heap_object(HeapObject::cast(object));
}

void BaseSnapshotWriter::write_external_object_table(Object** table, int length) {
  ASSERT(length >= 0);
  write_cardinal(length);
  for (int i = 0; i < length; i++) {
    write_object(table[i]);
  }
  _allocator.allocate_pointers(length);
}

void BaseSnapshotWriter::write_list_int32(List<int32> list) {
  write_int32(list.length());
  for (int i = 0; i < list.length(); i++) {
    // Use `write_int32` to make sure endianness is not an issue.
    write_int32(list[i]);
  }
  _allocator.allocate_int32s(list.length());
}

void BaseSnapshotWriter::write_list_uint16(List<uint16> list) {
  write_int32(list.length());
  for (int i = 0; i < list.length(); i++) {
    // Use `write_uint16` to make sure endianness is not an issue.
    write_uint16(list[i]);
  }
  _allocator.allocate_uint16s(list.length());
}

void BaseSnapshotWriter::write_list_uint8(List<uint8> list) {
  write_int32(list.length());
  write_bytes(list.data(), list.length());
  _allocator.allocate_bytes(list.length());
}

static int optional_length(HeapObject* object, Program* program) {
  switch (object->class_tag()) {
  case TypeTag::ARRAY_TAG: return Array::cast(object)->length();
  case TypeTag::BYTE_ARRAY_TAG: return ByteArray::Bytes(ByteArray::cast(object)).length();
  case TypeTag::STRING_TAG: return String::cast(object)->length();
  case TypeTag::INSTANCE_TAG: return Instance::cast(object)->length(program->instance_size_for(object));
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
  int length = optional_length(object, _program);
  write_object_header(is_target ? SnapshotTypeTag::IN_TABLE_TAG : SnapshotTypeTag::OBJECT_TAG,
                      length);
  write_byte(tag);
  _allocator.allocate_object(tag, length);
  ASSERT(object->header()->is_smi());
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
      Instance::cast(object)->write_content(_program->instance_size_for(object), this);
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
      : _relocation_bits(_new word[image.byte_size() / PAYLOAD_SIZE])
  , _image(image) {
    ASSERT(image.byte_size() % PAYLOAD_SIZE == 0);
    memset(_relocation_bits, 0, WORD_SIZE * (image.byte_size() / PAYLOAD_SIZE));
  }

  bool get_bit_for(word* addr) {
    int word_index = word_index_for(addr);
    int bit_number = bit_number_for(addr);
    return (_relocation_bits[word_index] >> bit_number) & 1U;
  }

  word get_bits_for_payload(int n) {
    return _relocation_bits[n];
  }

 public:
  void object_address(Object** p) {
    // Only make heap objects relocatable.
    if ((*p)->is_heap_object()) set_bit_for(reinterpret_cast<word*>(p));
  }

  void c_address(void** p, bool is_sentinel) {
    // Only make non null pointers relocatable.
    if (*p != null) {
      word* value = (word*) *p;
      ASSERT(_image.address_inside(value) ||
             (is_sentinel && value == _image.address()) + _image.byte_size());
      set_bit_for(reinterpret_cast<word*>(p));
    }
  }

 private:
  static const int PAYLOAD_SIZE = WORD_BIT_SIZE * WORD_SIZE;

  word* _relocation_bits;
  ProgramImage _image;

  void set_bit_for(word* addr) {
    int word_index = word_index_for(addr);
    int bit_number = bit_number_for(addr);
    _relocation_bits[word_index] |= 1UL << bit_number;
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
    ASSERT(_image.address_inside(addr));
    return Utils::address_distance(_image.begin(), addr);
  }
};

RelocationBits* ImageInputStream::build_relocation_bits(const ProgramImage& image) {
  RelocationBits* result = _new RelocationBits(image);
  image.do_pointers(result);
  return result;
}

ImageInputStream::ImageInputStream(const ProgramImage& image,
                                   RelocationBits* relocation_bits)
    : _image(image)
    , relocation_bits(relocation_bits)
    , current(image.begin())
    , index(0) {
}

int ImageInputStream::words_to_read() {
  ASSERT(!eos());
  int ready_words = Utils::address_distance(current, _image.end()) / WORD_SIZE;
  return Utils::min(ImageOutputStream::CHUNK_SIZE, 1 + ready_words);
}

int ImageInputStream::read(word* buffer) {
  ASSERT(!eos());
  int pos = 1;
  while (pos <= WORD_BIT_SIZE && (current < _image.end())) {
    word value = *current;
    if (relocation_bits->get_bit_for(current)) {
      value = Utils::address_distance(_image.begin(), reinterpret_cast<word*>(value));
      // Sentinels may point to `_image.end()`.
      ASSERT(value <= (word) Utils::address_distance(_image.begin(), _image.end()));
    }
    current = Utils::address_at(current, WORD_SIZE);
    buffer[pos++] = value;
  }
  buffer[0] = relocation_bits->get_bits_for_payload(index++);
  return pos;
}

#endif  // TOIT_FREERTOS

ImageOutputStream::ImageOutputStream(ProgramImage image)
    : _image(image)
    , current(image.begin()) {}

void ImageOutputStream::write(const word* buffer, int size, word* output) {
  ASSERT(1 < size && size <= CHUNK_SIZE);
  if (output == null) output = current;
  // The input buffer is often part of network packets with various headers,
  // so the embedded words aren't guaranteed to be word-aligned.
  word mask = Utils::read_unaligned_word(&buffer[0]);
  for (int index = 1; index < size; index++) {
    word value = Utils::read_unaligned_word(&buffer[index]);
    // Relocate value if needed with the address of the image.
    if (mask & 1U) value += reinterpret_cast<word>(_image.begin());
    mask = mask >> 1;
    output[index - 1] = value;
    current++;
  }
}

}  // namespace toit

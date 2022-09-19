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

#include "tags.h"
#include "top.h"
#include "utils.h"
#include "memory.h"

namespace toit {

class Printer;
class Blob;
class Chunk;
class MutableBlob;
class Error;
class Space;

enum BlobKind {
  STRINGS_OR_BYTE_ARRAYS,
  STRINGS_ONLY
};

enum GcType {
  NEW_SPACE_GC  = 0,
  FULL_GC       = 1,
  COMPACTING_GC = 2,
};

// Type testers.
INLINE bool is_smi(Object* o);
INLINE bool is_heap_object(Object* o);
INLINE bool is_double(Object* o);
INLINE bool is_task(Object* o);
INLINE bool is_instance(Object* o);
INLINE bool is_array(Object* o);
INLINE bool is_byte_array(Object* o);
INLINE bool is_stack(Object* o);
INLINE bool is_string(Object* o);
INLINE bool is_large_integer(Object* o);
INLINE bool is_free_list_region(Object* o);
INLINE bool is_promoted_track(Object* o);

class Object {
 public:
  static const int SMI_TAG_SIZE = 1;
  static const uword SMI_TAG_MASK = (1 << SMI_TAG_SIZE) - 1;
  static const int SMI_TAG = 0;

  static const int NON_SMI_TAG_OFFSET = 0;
  static const int NON_SMI_TAG_SIZE = 2;
  static const uword NON_SMI_TAG_MASK = (1 << NON_SMI_TAG_SIZE) - 1;
  static const int HEAP_TAG = 0x1;
  static const int MARKED_TAG = 0x3;

  static Object* cast(Object* obj) { return obj; }

  // Tells whether this is a temporary marked heap object.
  bool is_marked() {
    return (reinterpret_cast<uword>(this) & Object::NON_SMI_TAG_MASK) == MARKED_TAG;
  }

  INLINE HeapObject* unmark();

  // Primitive support that sets content and length iff receiver is String or ByteArray.
  // Returns whether the content and length are set.
  bool byte_content(Program* program, const uint8** content, int* length, BlobKind strings_only);

  // Same as above, but with a blob.
  bool byte_content(Program* program, Blob* blob, BlobKind strings_only);

  // Primitive support that sets content and length iff receiver is a ByteArray.
  // Returns whether the content and length are set.
  // The content can be set to `null` in which case the 'error' indicates the
  // reason. Most likely the function tried to allocate a ByteArray (for making a
  // CowByteArray mutable), but failed due to out-of-memory.
  bool mutable_byte_content(Process* process, uint8** content, int* length, Error** error);

  // Same as above, but with a blob.
  bool mutable_byte_content(Process* process, MutableBlob* blob, Error** error);

  // Encode this object using the encoder
  bool encode_on(ProgramOrientedEncoder* encoder);
};

// A class that combines a memory address with the size of it.
class Blob {
 public:
  Blob() : _address(null), _length(0) {}
  Blob(const uint8* address, int length)
      : _address(address), _length(length) {}

  const uint8* address() const { return _address; }
  int length() const { return _length; }

  bool slow_equals(const char* c_string) const;

 private:
  const uint8* _address;
  int _length;
};

// A class that combines a memory address with the size of it.
// Same as `Blob` but the mutable version of it.
class MutableBlob {
 public:
  MutableBlob() : _address(null), _length(0) {}
  MutableBlob(uint8* address, int length)
      : _address(address), _length(length) {}

  uint8* address() { return _address; }
  int length() { return _length; }

 private:
  uint8* _address;
  int _length;
};

// An error is a temporary object (a tagged string) only used for signaling a primitive has failed.
class Error : public Object {
 public:
  static INLINE Error* from(String* string);
  INLINE String* as_string();
};

class Smi : public Object {
 public:
  word value() const { return reinterpret_cast<word>(this) >> SMI_TAG_SIZE; }

  template<typename T> static bool is_valid(T value) {
    return (value >= MIN_SMI_VALUE) && (value <= MAX_SMI_VALUE);
  }

  static bool is_valid32(int64 value) {
    return (value >= MIN_SMI32_VALUE) && (value <= MAX_SMI32_VALUE);
  }

  static bool is_valid64(int64 value) {
    return (value >= MIN_SMI64_VALUE) && (value <= MAX_SMI64_VALUE);
  }

  static Smi* from(word value) {
    ASSERT(is_valid(value));
    return reinterpret_cast<Smi*>(static_cast<uword>(value) << SMI_TAG_SIZE);
  }

  static Smi* cast(Object* obj) {
    ASSERT(is_smi(obj));
    return static_cast<Smi*>(obj);
  }

  static Smi* zero() { return from(0); }
  static Smi* one() { return from(1); }

  static const word MIN_SMI_VALUE = -(((word)1) << (WORD_BIT_SIZE - (SMI_TAG_SIZE + 1)));
  static const word MAX_SMI_VALUE = (((word)1) << (WORD_BIT_SIZE - (SMI_TAG_SIZE + 1))) - 1;

  static const word MIN_SMI32_VALUE = -(((word)1) << (32 - (SMI_TAG_SIZE + 1)));
  static const word MAX_SMI32_VALUE = (((word)1) << (32 - (SMI_TAG_SIZE + 1))) - 1;

  static const int64 MIN_SMI64_VALUE = -(1LL << (64 - (SMI_TAG_SIZE + 1)));
  static const int64 MAX_SMI64_VALUE = (1LL << (64 - (SMI_TAG_SIZE + 1))) - 1;
};

class RootCallback {
 public:
  void do_root(Object** root) { do_roots(root, 1); }
  virtual void do_roots(Object** roots, int length) = 0;
};

// Note that these enum numbers must match the constants (called TAG) found in
// the corresponding classes in snapshot.toit.
enum TypeTag {
  ARRAY_TAG = 0,
  STRING_TAG = 1,
  INSTANCE_TAG = 2,
  ODDBALL_TAG = 3,
  DOUBLE_TAG = 4,
  BYTE_ARRAY_TAG = 5,
  LARGE_INTEGER_TAG,
  STACK_TAG,
  TASK_TAG,
  FREE_LIST_REGION_TAG,
  SINGLE_FREE_WORD_TAG,
  PROMOTED_TRACK_TAG,
};

class HeapObject : public Object {
 public:
  INLINE Smi* header() {
    Object* result = _at(HEADER_OFFSET);
    ASSERT(is_smi(result));
    return Smi::cast(result);
  }
  INLINE Smi* class_id() {
    return Smi::from((header()->value() >> HeapObject::CLASS_ID_OFFSET) & HeapObject::CLASS_ID_MASK);
  }
  INLINE TypeTag class_tag() {
    return static_cast<TypeTag>((header()->value() >> HeapObject::CLASS_TAG_OFFSET) & HeapObject::CLASS_TAG_MASK);
  }

  INLINE bool has_forwarding_address() {
    return is_heap_object(_at(HEADER_OFFSET));
  }

  // During GC the header can be a heap object (a forwarding pointer).
  INLINE HeapObject* forwarding_address() {
    ASSERT(has_forwarding_address());
    return HeapObject::cast(_at(HEADER_OFFSET));
  }

  INLINE void set_forwarding_address(HeapObject* destination) {
    _at_put(HEADER_OFFSET, destination);
  }

  // For asserts.  The remembered set is a card marking scheme, so it may
  // return true when neighbouring objects are in the set.  Always returns true
  // for objects in the new-space.
  bool in_remembered_set();

  // Pseudo virtual member functions.
  int size(Program* program);  // Returns the byte size of this object.
  void roots_do(Program* program, RootCallback* cb);  // For GC.
  void do_pointers(Program* program, PointerCallback* cb);  // For snapshots.

  // The header contains either a Smi that represents the class id/class
  // tag or a HeapObject which is a forwarding pointer during scavenge.
  static const int HEADER_OFFSET = Object::NON_SMI_TAG_OFFSET;

  static const int CLASS_TAG_BIT_SIZE = 4;
  static const int CLASS_TAG_OFFSET = 0;
  static const uword CLASS_TAG_MASK = (1 << CLASS_TAG_BIT_SIZE) - 1;

  static const int CLASS_ID_BIT_SIZE = 10;
  static const int CLASS_ID_OFFSET = CLASS_TAG_OFFSET + CLASS_TAG_BIT_SIZE;
  // This mask lets class_id() return negative values.  The GC uses
  // negative class ids for on-heap pseudo-objects like free memory.
  static const uword CLASS_ID_MASK = -1;

  static const int SIZE = HEADER_OFFSET + WORD_SIZE;

  // Operations for temporary marking a heap object.
  // Used for returning an error object when a primitive fails and
  // used in the class field to mark a forwarding pointer.
  HeapObject* mark() {
    ASSERT(!is_marked());
    uword raw = reinterpret_cast<uword>(this) | 0x3;
    HeapObject* result = reinterpret_cast<HeapObject*>(raw);
    ASSERT(result->is_marked());
    return result;
  }

  static HeapObject* cast(Object* obj) {
    ASSERT(is_heap_object(obj));
    return static_cast<HeapObject*>(obj);
  }

  static HeapObject* cast(void* address) {
    uword value = reinterpret_cast<uword>(address);
    ASSERT((value & NON_SMI_TAG_MASK) == SMI_TAG);
    return reinterpret_cast<HeapObject*>(value + HEAP_TAG);
  }

  static HeapObject* from_address(uword address) {
    ASSERT((address & NON_SMI_TAG_MASK) == SMI_TAG);
    return reinterpret_cast<HeapObject*>(address + HEAP_TAG);
  }

  inline bool on_program_heap(Process* process);

  static int allocation_size() { return _align(SIZE); }
  static void allocation_size(int* word_count, int* extra_bytes) {
    *word_count = SIZE / WORD_SIZE;
    *extra_bytes = 0;
  }

  // Not very fast - used for asserts.
  bool contains_pointers_to(Program* program, Space* space);

  bool is_a_free_object();

 protected:
  void _set_header(Smi* class_id, TypeTag class_tag) {
    uword header = class_id->value();
    header = (header << CLASS_TAG_BIT_SIZE) | class_tag;

    _set_header(Smi::from(header));
    ASSERT(this->class_id() == class_id);
    ASSERT(this->class_tag() == class_tag);
  }

  INLINE void _set_header(Smi* header){
    _at_put(HEADER_OFFSET, header);
  }

  void _set_header(Program* program, Smi* id);

  uword _raw() const { return reinterpret_cast<uword>(this) - HEAP_TAG; }
  uword* _raw_at(int offset) { return reinterpret_cast<uword*>(_raw() + offset); }

  Object* _at(int offset) { return *reinterpret_cast<Object**>(_raw_at(offset)); }
  void _at_put(int offset, Object* value) { *reinterpret_cast<Object**>(_raw_at(offset)) = value; }
  Object** _root_at(int offset) { return reinterpret_cast<Object**>(_raw_at(offset)); }

  uword _word_at(int offset) { return *_raw_at(offset); }
  void _word_at_put(int offset, uword value) { *_raw_at(offset) = value; }

  uint8 _byte_at(int offset) { return *reinterpret_cast<uint8*>(_raw_at(offset)); }
  void _byte_at_put(int offset, uint8 value) { *reinterpret_cast<uint8*>(_raw_at(offset)) = value; }

  uhalf_word _half_word_at(int offset) { return *reinterpret_cast<uhalf_word*>(_raw_at(offset)); }
  void _half_word_at_put(int offset, uhalf_word value) { *reinterpret_cast<uhalf_word*>(_raw_at(offset)) = value; }

  double _double_at(int offset) { return bit_cast<double>(_int64_at(offset)); }
  void _double_at_put(int offset, double value) { _int64_at_put(offset, bit_cast<int64>(value)); }

  int64 _int64_at(int offset) { return *reinterpret_cast<int64*>(_raw_at(offset)); }
  void _int64_at_put(int offset, int64 value) { *reinterpret_cast<int64*>(_raw_at(offset)) = value; }

  static int _align(int byte_size) { return (byte_size + (WORD_SIZE - 1)) & ~(WORD_SIZE - 1); }

  friend class ScavengeState;
  friend class ObjectHeap;
  friend class Space;
  friend class SemiSpace;
  friend class OldSpace;
  friend class ProgramHeap;
  friend class TwoSpaceHeap;
  friend class BaseSnapshotWriter;
  friend class SnapshotReader;
  friend class compiler::ProgramBuilder;
  friend class Stack;
  friend class GcMetadata;
  friend class CompactingVisitor;
  friend class SweepingVisitor;
  friend class ScavengeVisitor;
};

class Array : public HeapObject {
 public:
  int length() { return _word_at(LENGTH_OFFSET); }

  static INLINE int max_length_in_process();
  static INLINE int max_length_in_program();

  // Must match collections.toit.
  static const int ARRAYLET_SIZE = 500;

  INLINE Object* at(int index) {
    ASSERT(index >= 0 && index < length());
    return _at(_offset_from(index));
  }

  INLINE void at_put(int index, Smi* value) {
    ASSERT(index >= 0 && index < length());
    _at_put(_offset_from(index), value);
  }

  INLINE void at_put(int index, Object* value);

  INLINE void at_put_no_write_barrier(int index, Object* value) {
    ASSERT(index >= 0 && index < length());
    _at_put(_offset_from(index), value);
  }

  void copy_from(Array* other, int length) {
    memcpy(content(), other->content(), length * WORD_SIZE);
  }

  uint8* content() { return reinterpret_cast<uint8*>(_raw() + _offset_from(0)); }


  int size() { return allocation_size(length()); }

  void roots_do(RootCallback* cb);

#ifndef TOIT_FREERTOS
  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st, int length);
#endif

  static Array* cast(Object* array) {
     ASSERT(is_array(array));
     return static_cast<Array*>(array);
  }

  Object** base() { return reinterpret_cast<Object**>(_raw_at(_offset_from(0))); }

  static int allocation_size(int length) { return  _align(_offset_from(length)); }

  static void allocation_size(int length, int* word_count, int* extra_bytes) {
    *word_count = HEADER_SIZE / WORD_SIZE + length;
    *extra_bytes = 0;
  }

  void fill(int from, Object* filler);

 private:
  static const int LENGTH_OFFSET = HeapObject::SIZE;
  static const int HEADER_SIZE = LENGTH_OFFSET + WORD_SIZE;

  void _set_length(int value) { _word_at_put(LENGTH_OFFSET, value); }

  // Can only be called on newly allocated objects that will be either
  // in new-space or were added to the remembered set on creation.
  // Is also called from the compiler, where there are no write barriers.
  void _initialize_no_write_barrier(int length, Object* filler) {
    _set_length(length);
    for (int index = 0; index < length; index++) {
      at_put_no_write_barrier(index, filler);
    }
  }

  void _initialize(int length) {
    _set_length(length);
  }

  friend class ObjectHeap;
  friend class ProgramHeap;

 protected:
  static int _offset_from(int index) { return HEADER_SIZE + index * WORD_SIZE; }
};


class ByteArray : public HeapObject {
 public:
  // Abstraction to access the content of a ByteArray.
  // Note that a ByteArray can have two representations.
  class Bytes {
   public:
    explicit Bytes(ByteArray* array) {
      int l = array->raw_length();
      if (l >= 0) {
        _address = array->content();
        _length = l;
      } else {
        _address = array->as_external();
        _length = -1 -l;
      }
      ASSERT(length() >= 0);
    }
    Bytes(uint8* address, const int length) : _address(address), _length(length) {}

    uint8* address() { return _address; }
    int length() { return _length; }

    uint8 at(int index) {
      ASSERT(index >= 0 && index < length());
      return *(address() + index);
    }

    void at_put(int index, uint8 value) {
      ASSERT(index >= 0 && index < length());
      *(address() + index) = value;
    }

    bool is_valid_index(int index) {
      return index >= 0 && index < length();
    }

   private:
    uint8* _address;
    int _length;
  };

  bool has_external_address() { return raw_length() < 0; }

  template<typename T> T* as_external();

  static inline word max_internal_size_in_process();
  static inline word max_internal_size_in_program();
  static word max_internal_size();

  uint8* as_external() {
    ASSERT(external_tag() == RawByteTag || external_tag() == NullStructTag);
    if (has_external_address()) return unsigned_cast(_external_address());
    return 0;
  }

  int size() {
    return has_external_address()
         ? external_allocation_size()
         : internal_allocation_size(raw_length());
  }

  static int external_allocation_size() {
    return EXTERNAL_SIZE;
  }
  static void external_allocation_size(int* word_count, int* extra_bytes) {
    *word_count = EXTERNAL_SIZE / WORD_SIZE;
    *extra_bytes = 0;
  }

  static int internal_allocation_size(int raw_length) {
    ASSERT(raw_length >= 0);
    return _align(_offset_from(raw_length));
  }

  static void internal_allocation_size(int raw_length, int* word_count, int* extra_bytes) {
    ASSERT(raw_length >= 0);
    *word_count = HEADER_SIZE / WORD_SIZE;
    *extra_bytes = raw_length;
  }

#ifndef TOIT_FREERTOS
  static void snapshot_allocation_size(int length, int* word_count, int* extra_bytes) {
    if (length > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
      return external_allocation_size(word_count, extra_bytes);
    } else {
      return internal_allocation_size(length, word_count, extra_bytes);
    }
  }

  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st, int byte_length);
#endif

  static ByteArray* cast(Object* byte_array) {
     ASSERT(is_byte_array(byte_array));
     return static_cast<ByteArray*>(byte_array);
  }

  // Only for external byte arrays that were malloced.  Does not change the
  // accounting, so we may overestimate the external memory pressure.  May fail
  // under memory pressure, in which case the size of the Toit ByteArray object
  // is changed, but the backing harmlessly points to a larger area.
  void resize_external(Process* process, word new_length);

  template<typename T> void set_external_address(T* value) {
    _set_external_address(reinterpret_cast<uint8*>(value));
    _set_external_tag(T::tag);
  }

  void set_external_address(int length, uint8* value) {
    _initialize_external_memory(length, value, false);
  }

  void clear_external_address() {
    _set_external_address(null);
  }

  uint8* neuter(Process* process);

  word external_tag() {
    ASSERT(has_external_address());
    return _word_at(EXTERNAL_TAG_OFFSET);
  }

  void do_pointers(PointerCallback* cb);

 private:
  word raw_length() { return _word_at(LENGTH_OFFSET); }
  uint8* content() { return reinterpret_cast<uint8*>(_raw() + _offset_from(0)); }

  static const int LENGTH_OFFSET = HeapObject::SIZE;
  static const int HEADER_SIZE = LENGTH_OFFSET + WORD_SIZE;

  // Constants for external representation.
  static const int EXTERNAL_ADDRESS_OFFSET = HEADER_SIZE;
  static_assert(EXTERNAL_ADDRESS_OFFSET % WORD_SIZE == 0, "External pointer not word aligned");
  static const int EXTERNAL_TAG_OFFSET = EXTERNAL_ADDRESS_OFFSET + WORD_SIZE;
  static const int EXTERNAL_SIZE = EXTERNAL_TAG_OFFSET + WORD_SIZE;

  // Any byte-array that is bigger than this size is snapshotted as external
  // byte array.
  static const int SNAPSHOT_INTERNAL_SIZE_CUTOFF = TOIT_PAGE_SIZE_32 >> 2;

  uint8* _external_address() {
    return reinterpret_cast<uint8*>(_word_at(EXTERNAL_ADDRESS_OFFSET));
  }

  void _set_external_address(uint8* value) {
    ASSERT(has_external_address());
    _word_at_put(EXTERNAL_ADDRESS_OFFSET, reinterpret_cast<word>(value));
  }

  void _set_external_tag(word value) {
    ASSERT(has_external_address());
    _word_at_put(EXTERNAL_TAG_OFFSET, value);
  }

  void _set_length(int value) { _word_at_put(LENGTH_OFFSET, value); }

  void _set_external_length(int length) { _set_length(-1 - length); }

  int _external_length() {
    ASSERT(has_external_address());
    return -1 - raw_length();
  }

  void _clear() {
    Bytes bytes(this);
    memset(bytes.address(), 0, bytes.length());
  }

  void _initialize(int length) {
    _set_length(length);
    _clear();
  }

  void _initialize_external_memory(int length, uint8* external_address, bool clear_content = true) {
    ASSERT(length >= 0);
    _set_external_length(length);
    _set_external_address(external_address);
    if (external_address == null) {
      _set_external_tag(NullStructTag);
    } else {
      _set_external_tag(RawByteTag);
    }
    if (clear_content) _clear();
  }

  friend class ObjectHeap;
  friend class ProgramHeap;
  friend class ShortPrintVisitor;
  friend class VMFinalizerNode;

 protected:
  static int _offset_from(int index) {
    ASSERT(index >= 0);
    ASSERT(index <= max_internal_size());
    return HEADER_SIZE + index;
  }

 public:
  // Constants that should be elsewhere.
  static const int MIN_IO_BUFFER_SIZE = 1;
  // Selected to be able to contain most MTUs (1500), but still align to 512 bytes.
  static const int PREFERRED_IO_BUFFER_SIZE = 1536 - HEADER_SIZE;
};


class LargeInteger : public HeapObject {
 public:
  int64 value() { return _int64_at(VALUE_OFFSET); }

  static LargeInteger* cast(Object* value) {
     ASSERT(is_large_integer(value));
     return static_cast<LargeInteger*>(value);
  }

  static int allocation_size() { return SIZE; }
  static void allocation_size(int* word_count, int* extra_bytes) {
    *word_count = HeapObject::SIZE / WORD_SIZE;
    *extra_bytes = 8;
  }

 private:
  static const int VALUE_OFFSET = HeapObject::SIZE;
  static const int SIZE = VALUE_OFFSET + INT64_SIZE;

  void _initialize(int64 value) { _set_value(value); }
  void _set_value(int64 value) {
    ASSERT(!Smi::is_valid(value));
    _int64_at_put(VALUE_OFFSET, value);
  }
  friend class ObjectHeap;
  friend class ProgramHeap;
  friend class SnapshotReader;
};


class FrameCallback {
 public:
  virtual void do_frame(Stack* frame, int number, int absolute_bci) { }
};


class Stack : public HeapObject {
 public:
  INLINE Task* task();
  INLINE void set_task(Task* value);

  int length() { return _word_at(LENGTH_OFFSET); }
  int top() { return _word_at(TOP_OFFSET); }
  int try_top() { return _word_at(TRY_TOP_OFFSET); }

  int absolute_bci_at_preemption(Program* program);

  void transfer_to_interpreter(Interpreter* interpreter);
  void transfer_from_interpreter(Interpreter* interpreter);

  int size() { return allocation_size(length()); }

  void copy_to(HeapObject* other, int other_length);

  void roots_do(Program* program, RootCallback* cb);

  // Iterates over all frames on this stack and returns the number of frames.
  int frames_do(Program* program, FrameCallback* cb);

  static INLINE int initial_length() { return 64; }
  static INLINE int max_length();

  static Stack* cast(Object* stack) {
    ASSERT(is_stack(stack));
    return static_cast<Stack*>(stack);
  }

  static int allocation_size(int length) { return  _align(HEADER_SIZE + length * WORD_SIZE); }
  static void allocation_size(int length, int* word_count, int* extra_bytes) {
    ASSERT(length > 0);
    *word_count = HEADER_SIZE / WORD_SIZE + length;
    *extra_bytes = 0;
  }

 private:
  static const int TASK_OFFSET = HeapObject::SIZE;
  static const int LENGTH_OFFSET = TASK_OFFSET + WORD_SIZE;
  static const int TOP_OFFSET = LENGTH_OFFSET + WORD_SIZE;
  static const int TRY_TOP_OFFSET = TOP_OFFSET + WORD_SIZE;
  static const int HEADER_SIZE = TRY_TOP_OFFSET + WORD_SIZE;

  void _set_length(int value) { _word_at_put(LENGTH_OFFSET, value); }
  void _set_top(int value) { _word_at_put(TOP_OFFSET, value); }
  void _set_try_top(int value) { _word_at_put(TRY_TOP_OFFSET, value); }

  void _initialize(int length) {
    _set_length(length);
    _set_top(length);
    _set_try_top(length);
  }

  Object** _stack_base_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(length()))); }
  Object** _stack_limit_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(0))); }
  Object** _stack_sp_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(top()))); }
  Object** _stack_try_sp_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(try_top()))); }

  Object* at(int index) {
    ASSERT((_stack_sp_addr() + index) < _stack_base_addr());
    return *(_stack_sp_addr() + index);
  }

  Object** _from_block(Smi* block) {
    return _stack_base_addr() - (block->value() - BLOCK_SALT);
  }

  Smi* _to_block(Object** pointer) {
    return Smi::from(_stack_base_addr() - pointer + BLOCK_SALT);
  }

  bool is_inside(Object** value) {
    return (_stack_base_addr() > value) && (value >= _stack_sp_addr());
  }

  uword* _array_address(int index) { return _raw_at(_array_offset_from(index)); }
  static int _array_offset_from(int index) { return HEADER_SIZE + index  * WORD_SIZE; }

  friend class ObjectHeap;
  friend class ProgramHeap;
};

class Double : public HeapObject {
 public:
  double value() { return _double_at(VALUE_OFFSET); }
  int64 bits() { return _int64_at(VALUE_OFFSET); }

  static Double* cast(Object* value) {
     ASSERT(is_double(value));
     return static_cast<Double*>(value);
  }

#ifndef TOIT_FREERTOS
  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st);
#endif

  static int allocation_size() { return SIZE; }
  static void allocation_size(int* word_count, int* extra_bytes) {
    *word_count = HeapObject::SIZE / WORD_SIZE;
    *extra_bytes = 8;
  }

 private:
  static const int VALUE_OFFSET = HeapObject::SIZE;
  static const int SIZE = VALUE_OFFSET + DOUBLE_SIZE;

  void _initialize(double value) { _set_value(value); }
  void _set_value(double value) { _double_at_put(VALUE_OFFSET, value); }
  friend class ObjectHeap;
  friend class ProgramHeap;
};

class String : public HeapObject {
 public:
  uint16 hash_code() {
    int result = _raw_hash_code();
    return result != NO_HASH_CODE ? result : _assign_hash_code();
  }

  int length() {
     int result = _internal_length();
     return result != SENTINEL ? result : _external_length();
  }

  // Tells whether the string content is on the heap or external.
  bool content_on_heap() { return _internal_length() != SENTINEL; }

  static INLINE int max_length_in_process();
  static INLINE int max_length_in_program();

  bool is_empty() { return length() == 0; }

  int size() {
    int len = _internal_length();
    if (len != SENTINEL) return internal_allocation_size(length());
    return external_allocation_size();
  }

  bool equals(Object* other);
  bool slow_equals(const char* string, int string_length);
  bool slow_equals(const char* string);
  static bool slow_equals(const char* string_a, int length_a, const char* string_b, int length_b) {
    return length_a == length_b && memcmp(string_a, string_b, length_a) == 0;
  }
  static bool slow_equals(const uint8* bytes_a, int length_a, const uint8* bytes_b, int length_b) {
    return length_a == length_b && memcmp(bytes_a, bytes_b, length_a) == 0;
  }

  bool starts_with_vowel();

  // Returns -1, 0, or 1.
  int compare(String* other);
  static int compare(const char* string_a, int length_a, const char* string_b, int length_b) {
    int min_len;
    int equal_result;
    // We don't just use strcmp, in case one of the strings contains a '\0'.
    if (length_a == length_b) {
      min_len = length_a;
      equal_result = 0;
    } else if (length_a < length_b) {
      min_len = length_a;
      equal_result = -1;
    } else {
      min_len = length_b;
      equal_result = 1;
    }
    int comp = memcmp(string_a, string_b, min_len);
    if (comp == 0) return equal_result;
    if (comp < 0) return -1;
    return 1;
  }
  static int compare(const uint8* bytes_a, int length_a, const uint8* bytes_b, int length_b) {
    return compare(reinterpret_cast<const char*>(bytes_a),
                   length_a,
                   reinterpret_cast<const char*>(bytes_b),
                   length_b);
  }

  uint16 compute_hash_code();
  static uint16 compute_hash_code_for(const char* str, int str_len);
  static uint16 compute_hash_code_for(const char* str);

#ifndef TOIT_FREERTOS
  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st, int length);
#endif

  // Returns a derived pointer that can be used as a null terminated c string.
  // Not all returned objects are mutable.
  // If the string is a literal it lives in a read-only area.
  char* as_cstr() {
    return reinterpret_cast<char*>(_as_utf8bytes());
  }

  // Returns a malloced string with the same content as this string.
  char* cstr_dup();

  static String* cast(Object* object) {
     ASSERT(is_string(object));
     return static_cast<String*>(object);
  }

  static inline word max_internal_size_in_process();
  static inline word max_internal_size_in_program();
  static word max_internal_size();

  static int internal_allocation_size(int length) {
    return _align(_offset_from(length+1));
  }
  static void internal_allocation_size(int length, int* word_count, int* extra_bytes) {
    ASSERT(length <= max_internal_size());
    // The length and hash-code are stored as half-word sizes.
    static_assert(INTERNAL_HEADER_SIZE == HeapObject::SIZE + 2 * HALF_WORD_SIZE,
                  "Unexpected string layout");
    *word_count = HeapObject::SIZE / WORD_SIZE;
    *extra_bytes = length + OVERHEAD - HeapObject::SIZE;
  }

  static int external_allocation_size() { return _align(EXTERNAL_OBJECT_SIZE); }
  static void external_allocation_size(int* word_count, int* extra_bytes) {
    *word_count = external_allocation_size() / WORD_SIZE;
    *extra_bytes = 0;
  }

#ifndef TOIT_FREERTOS
  static void snapshot_allocation_size(int length, int* word_count, int* extra_bytes) {
    if (length > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
      return external_allocation_size(word_count, extra_bytes);
    } else {
      return internal_allocation_size(length, word_count, extra_bytes);
    }
  }
#endif

  void do_pointers(PointerCallback* cb);

  // Abstraction to access the read-only content of a String.
  // Note that a String can either have on-heap or off-heap content.
  class Bytes {
   public:
    explicit Bytes(String* string) {
      int len = string->_internal_length();
      if (len != SENTINEL) {
        _address = string->_as_utf8bytes();
        _length = len;
      } else {
        _address = string->as_external();
        _length = string->_external_length();
      }
      ASSERT(length() >= 0);
    }
    Bytes(uint8* address, const int length) : _address(address), _length(length) {}

    uint8* address() { return _address; }
    int length() { return _length; }

    uint8 at(int index) {
      ASSERT(index >= 0 && index < length());
      return *(address() + index);
    }

    void _initialize(const char* str) {
      memcpy(address(), str, length());
    }

    void _initialize(int index, String* other, int start, int length) {
      Bytes ot(other);
      memcpy(address() + index, ot.address() + start, length);
    }

    void _initialize(int index, const uint8* chars, int start, int length) {
      memcpy(address() + index, chars + start, length);
    }

    void _at_put(int index, uint8 value) {
      ASSERT(index >= 0 && index < length());
      *(address() + index) = value;
    }

    // Set zero at end to make content C look alike.
    void _set_end() {
      *(address() + length()) = 0;
    }

    bool is_valid_index(int index) {
      return index >= 0 && index < length();
    }

   private:
    uint8* _address;
    int _length;
  };

 private:
  // Two representations
  // in heap content:  [class:w][hash_code:h][length:h][content:byte*length][0][padding]
  // off heap content: [class:w][hash_code:h][-1:h]    [length:w][external_address:w]
  // The first length field will also be used or tagging, recognizing an external representation.
  // Please note that if need be it is easy to extend the width of hash_code for strings with off heap content.
  static const int SENTINEL = 65535;
  static_assert(SENTINEL > TOIT_PAGE_SIZE, "Sentinel must not be legal internal length");
  static const int HASH_CODE_OFFSET = HeapObject::SIZE;
  static const int INTERNAL_LENGTH_OFFSET = HASH_CODE_OFFSET + HALF_WORD_SIZE;
  static const int INTERNAL_HEADER_SIZE = INTERNAL_LENGTH_OFFSET + HALF_WORD_SIZE;
  static const word OVERHEAD = INTERNAL_HEADER_SIZE + 1;
  static const uint16 NO_HASH_CODE = 0xFFFF;

  static const int EXTERNAL_LENGTH_OFFSET = INTERNAL_HEADER_SIZE;
  static const int EXTERNAL_ADDRESS_OFFSET = EXTERNAL_LENGTH_OFFSET + WORD_SIZE;
  static_assert(EXTERNAL_ADDRESS_OFFSET % WORD_SIZE == 0, "External pointer not word aligned");
  static const int EXTERNAL_OBJECT_SIZE = EXTERNAL_ADDRESS_OFFSET + WORD_SIZE;

  // Any string that is bigger than this size is snapshotted as external string.
  static const int SNAPSHOT_INTERNAL_SIZE_CUTOFF = TOIT_PAGE_SIZE_32 >> 2;

  uint16 _raw_hash_code() { return _half_word_at(HASH_CODE_OFFSET); }
  void _raw_set_hash_code(uint16 value) { _half_word_at_put(HASH_CODE_OFFSET, value); }
  void _set_length(int value) { _half_word_at_put(INTERNAL_LENGTH_OFFSET, value); }

  static int _offset_from(int index) {
    ASSERT(index >= 0);
    // We allow _offset_from of the null at the end of an internal string, so
    // add one to the limit here.
    ASSERT(index <= max_internal_size() + 1);
    return INTERNAL_HEADER_SIZE + index;
  }
  uint16 _assign_hash_code();

  uint8* _as_utf8bytes() {
    if (content_on_heap()) {
      return reinterpret_cast<uint8*>(_raw_at(INTERNAL_HEADER_SIZE));
    }
    return _external_address();
  }

  int _internal_length() {
     return _half_word_at(INTERNAL_LENGTH_OFFSET);
  }

  int _external_length() {
     ASSERT(_internal_length() == SENTINEL);
     return _word_at(EXTERNAL_LENGTH_OFFSET);
  }

  void _set_external_length(int value) {
    _set_length(SENTINEL);
    _word_at_put(EXTERNAL_LENGTH_OFFSET, value);
  }

  uint8* as_external() {
    if (!content_on_heap()) return unsigned_cast(_external_address());
    return null;
  }

  void clear_external_address() {
    _set_external_address(null);
  }

  uint8* _external_address() {
    return reinterpret_cast<uint8*>(_word_at(EXTERNAL_ADDRESS_OFFSET));
  }

  void _set_external_address(const uint8* value) {
    ASSERT(!content_on_heap());
    _word_at_put(EXTERNAL_ADDRESS_OFFSET, reinterpret_cast<word>(value));
  }

  bool _is_valid_utf8();

  friend class ObjectHeap;
  friend class ProgramHeap;
  friend class VMFinalizerNode;
};

class Method {
 public:
  Method(List<uint8> all_bytes, int offset) : Method(&all_bytes[offset]) {}
  Method(uint8* bytes) : _bytes(bytes) { }

  static Method invalid() { return Method(null); }
  static int allocation_size(int bytecode_size, int max_height) {
    return HEADER_SIZE + bytecode_size;
  }

  bool is_valid() const { return _bytes != null; }

  bool is_normal_method() const { return _kind() == METHOD; }
  bool is_block_method() const { return  _kind() == BLOCK; }
  bool is_lambda_method() const { return _kind() == LAMBDA; }
  bool is_field_accessor() const { return _kind() == FIELD_ACCESSOR; }

  int arity() const { return _bytes[ARITY_OFFSET]; }
  int captured_count() const { return _value(); }
  int selector_offset() const { return _value(); }
  uint8* entry() const { return &_bytes[ENTRY_OFFSET]; }
  int max_height() const { return (_bytes[KIND_HEIGHT_OFFSET] >> KIND_BITS) * 4; }

  uint8* bcp_from_bci(int bci) const { return &_bytes[ENTRY_OFFSET + bci]; }
  uint8* header_bcp() const { return _bytes; }

  static uint8* header_from_entry(uint8* entry) { return entry - ENTRY_OFFSET; }

 private: // Friend access for ProgramBuilder.
  void _initialize_block(int arity, List<uint8> bytecodes, int max_height) {
    _initialize(BLOCK, 0, arity, bytecodes, max_height);
    ASSERT(this->arity() == arity);
    ASSERT(!this->is_field_accessor());
  }

  void _initialize_lambda(int captured_count, int arity, List<uint8> bytecodes, int max_height) {
    _initialize(LAMBDA, captured_count, arity, bytecodes, max_height);
    ASSERT(this->arity() == arity);
    ASSERT(!this->is_field_accessor());
    ASSERT(this->captured_count() == captured_count);
  }

  void _initialize_method(int selector_offset, bool is_field_accessor, int arity, List<uint8> bytecodes, int max_height) {
    Kind kind = is_field_accessor ? FIELD_ACCESSOR : METHOD;
    _initialize(kind, selector_offset, arity, bytecodes, max_height);
    ASSERT(this->arity() == arity);
    ASSERT(this->selector_offset() == selector_offset);
  }

  friend class compiler::ProgramBuilder;

 private:
  static const int ARITY_OFFSET = 0;
  static const int KIND_HEIGHT_OFFSET = ARITY_OFFSET + BYTE_SIZE;
  static const int KIND_BITS = 2;
  static const int KIND_MASK = (1 << KIND_BITS) - 1;
  static const int HEIGHT_BITS = 8 - KIND_BITS;
  static const int VALUE_OFFSET = KIND_HEIGHT_OFFSET + BYTE_SIZE;
  static const int ENTRY_OFFSET = VALUE_OFFSET + 2;
  static const int HEADER_SIZE = ENTRY_OFFSET;

  uint8* _bytes;

  enum Kind { METHOD = 0, LAMBDA, BLOCK, FIELD_ACCESSOR };

  Kind _kind() const { return static_cast<Kind>(_bytes[KIND_HEIGHT_OFFSET] & KIND_MASK); }

  void _initialize(Kind kind, int value, int arity, List<uint8> bytecodes, int max_height) {
    ASSERT(0 <= arity && arity < (1 <<  BYTE_BIT_SIZE));
    _set_kind_height(kind, max_height);
    _set_arity(arity);
    _set_value(value);
    _set_bytecodes(bytecodes);

    ASSERT(this->_kind()  == kind);
    ASSERT(this->arity()  == arity);
    ASSERT(this->_value() == value);
  }

  int _int16_at(int offset) const {
    int16 result;
    memcpy(&result, &_bytes[offset], 2);
    return result;
  }

  void _set_int16_at(int offset, int value) {
    int16 source = value;
    memcpy(&_bytes[offset], &source, 2);
  }

  int _value() const { return _int16_at(VALUE_OFFSET); }
  void _set_value(int value) { _set_int16_at(VALUE_OFFSET, value); }

  void _set_arity(int arity) {
    ASSERT(arity <= 0xFF);
    _bytes[ARITY_OFFSET] = arity;
  }
  void _set_kind_height(Kind kind, int max_height) {
    // We need two bits for the kind.
    ASSERT(kind <= KIND_MASK);
    // We store multiples of 4 as max height.
    int scaled_height = (max_height + 3) / 4;
    const int MAX_SCALED_HEIGHT = (1 << HEIGHT_BITS) - 1;
    if (scaled_height > MAX_SCALED_HEIGHT) {
      FATAL("Max stack height too big");
    }
    int encoded_height = scaled_height << KIND_BITS;
    _bytes[KIND_HEIGHT_OFFSET] = kind | encoded_height;
  }
  void _set_captured_count(int value) { _set_value(value); }
  void _set_selector_offset(int value) { _set_value(value); }
  void _set_bytecodes(List<uint8> bytecodes) {
    if (bytecodes.length() > 0) {
      memcpy(&_bytes[ENTRY_OFFSET], bytecodes.data(), bytecodes.length());
    }
  }
};


class Instance : public HeapObject {
 public:
  Object* at(int index) {
    return _at(_offset_from(index));
  }

  INLINE void at_put(int index, Smi* value) {
    _at_put(_offset_from(index), value);
  }

  void at_put_no_write_barrier(int index, Object* value) {
    _at_put(_offset_from(index), value);
  }

  // Using this from the compiler will cause link errors.  Use
  // at_put_no_write_barrier in the compiler instead.
  void at_put(int index, Object* value);

  // Fills instance fields with Smi zero.
  void initialize(int instance_size);

  void roots_do(int instance_size, RootCallback* cb);

#ifndef TOIT_FREERTOS
  void write_content(int instance_size, SnapshotWriter* st);
  void read_content(SnapshotReader* st);
#endif

  // Returns the number of fields in an instance of the given size.
  static int fields_from_size(int instance_size) {
    return (instance_size - HEADER_SIZE) / WORD_SIZE;
  }

  static Instance* cast(Object* value) {
    ASSERT(is_instance(value) || is_task(value));
    return static_cast<Instance*>(value);
  }

  static int allocation_size(int length) { return  _align(_offset_from(length)); }
  static void allocation_size(int length, int* word_count, int* extra_bytes) {
    *word_count = HEADER_SIZE / WORD_SIZE + length;
    *extra_bytes = 0;
  }

  // Some of the instance types have field offsets that are known both
  // on the native and the Toit side.
  // These numbers must stay synced with the fields in collections.toit.
  static const int MAP_SIZE_INDEX        = 0;
  static const int MAP_SPACES_LEFT_INDEX = 1;
  static const int MAP_INDEX_INDEX       = 2;
  static const int MAP_BACKING_INDEX     = 3;

  static const int LIST_ARRAY_INDEX = 0;
  static const int LIST_SIZE_INDEX  = 1;

  static const int BYTE_ARRAY_COW_BACKING_INDEX    = 0;
  static const int BYTE_ARRAY_COW_IS_MUTABLE_INDEX = 1;

  static const int BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX = 0;
  static const int BYTE_ARRAY_SLICE_FROM_INDEX       = 1;
  static const int BYTE_ARRAY_SLICE_TO_INDEX         = 2;

  static const int LARGE_ARRAY_SIZE_INDEX   = 0;
  static const int LARGE_ARRAY_VECTOR_INDEX = 1;

  static const int STRING_SLICE_STRING_INDEX = 0;
  static const int STRING_SLICE_FROM_INDEX   = 1;
  static const int STRING_SLICE_TO_INDEX     = 2;

  static const int TOMBSTONE_DISTANCE_INDEX = 0;

 private:
  static const int HEADER_SIZE = HeapObject::SIZE;

  static int _offset_from(int index) { return HEADER_SIZE + index  * WORD_SIZE; }

  friend class ObjectHeap;
  friend class ProgramHeap;
};

/*
These objects are sometimes used to overwrite dead objects.  This
  means a heap can be made traversable, skipping over unused areas.
They are never accessible from Toit code.
*/
class FreeListRegion : public HeapObject {
 public:
  uword size() {
    if (class_tag() == SINGLE_FREE_WORD_TAG) return WORD_SIZE;
    ASSERT(class_tag() == FREE_LIST_REGION_TAG);
    return _word_at(SIZE_OFFSET);
  }

  bool can_be_daisychained() { return class_tag() == FREE_LIST_REGION_TAG; }

  void roots_do(int instance_size, RootCallback* cb) {}

  static FreeListRegion* cast(Object* value) {
    ASSERT(is_free_list_region(value));
    return static_cast<FreeListRegion*>(value);
  }

  void set_next_region(FreeListRegion* next) {
    ASSERT(can_be_daisychained());
    _at_put(NEXT_OFFSET, next);
  }

  FreeListRegion* next_region() {
    ASSERT(can_be_daisychained());
    Object* result = _at(NEXT_OFFSET);
    if (result == null) return null;
    return FreeListRegion::cast(result);
  }

  static FreeListRegion* create_at(uword start, uword size);

  static Object* single_free_word_header();

 private:
  static const int SIZE_OFFSET = HeapObject::SIZE;
  static const int NEXT_OFFSET = SIZE_OFFSET + WORD_SIZE;
  static const int MINIMUM_SIZE = NEXT_OFFSET + WORD_SIZE;
};

/*
These objects are container objects in which we allocate
  newly promoted objects in old space.  They are chained up
  so we can traverse the newly promoted objects during a
  scavenge.
After the header comes the newly allocated objects, perhaps
  followed by a FreeListRegion object to fill out the rest.
They are never accessible from Toit code.
*/
class PromotedTrack : public HeapObject {
 public:
  // Returns the whole size of the PromotedTrack so that
  // when traversing the heap we will skip the promoted track.
  // We only want to traverse the newly-promoted objects explicitly.
  uword size() {
    ASSERT(class_tag() == PROMOTED_TRACK_TAG);
    return end() - _raw();
  }

  // Returns the address of the first object in the track.
  uword start() {
    return _raw() + HEADER_SIZE;
  }

  // When traversing the stack we don't traverse the objects inside the
  // track, so nothing to do here.
  void roots_do(int instance_size, RootCallback* cb) {}

  static PromotedTrack* cast(Object* value) {
    ASSERT(is_promoted_track(value));
    return static_cast<PromotedTrack*>(value);
  }

  void set_next(PromotedTrack* next) {
    _at_put(NEXT_OFFSET, next);
  }

  PromotedTrack* next() {
    Object* result = _at(NEXT_OFFSET);
    if (result == null) return null;
    return PromotedTrack::cast(result);
  }

  void set_end(uword end) {
    _word_at_put(END_OFFSET, end);
  }

  uword end() {
    return _word_at(END_OFFSET);
  }

  // Overwrite the header of the PromotedTrack with free space so that
  // the heap becomes iterable.
  void zap();

  static PromotedTrack* initialize(PromotedTrack* next, uword start, uword end);

  static inline uword header_size() { return HEADER_SIZE; }

 private:
  static const int END_OFFSET = HeapObject::SIZE;
  static const int NEXT_OFFSET = END_OFFSET + WORD_SIZE;
  static const int HEADER_SIZE = NEXT_OFFSET + WORD_SIZE;
};

class Task : public Instance {
 public:
  static const int STACK_INDEX = 0;
  static const int ID_INDEX = STACK_INDEX + 1;
  static const int RESULT_INDEX = ID_INDEX + 1;

  Stack* stack() { return Stack::cast(at(STACK_INDEX)); }
  void set_stack(Stack* value);

  int id() { return Smi::cast(at(ID_INDEX))->value(); }

  inline void set_result(Object* value);

  static Task* cast(Object* value) {
    ASSERT(is_task(value));
    return static_cast<Task*>(value);
  }

  void detach_stack() {
    at_put(STACK_INDEX, Smi::zero());
  }

  bool has_stack() {
    return is_stack(at(STACK_INDEX));
  }

 private:
  void _initialize(Stack* stack, Smi* id);

  friend class ObjectHeap;
};

inline Task* Stack::task() {
  return Task::cast(_at(TASK_OFFSET));
}

inline bool is_smi(Object* o) {
  return (reinterpret_cast<uword>(o) & Object::SMI_TAG_MASK) == Object::SMI_TAG;
}

inline bool is_heap_object(Object* o) {
  return (reinterpret_cast<uword>(o) & Object::NON_SMI_TAG_MASK) == Object::HEAP_TAG;
}

inline bool is_double(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == DOUBLE_TAG;
}

inline bool is_task(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == TASK_TAG;
}

inline bool is_instance(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == INSTANCE_TAG;
}

inline bool is_array(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == ARRAY_TAG;
}

inline bool is_byte_array(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == BYTE_ARRAY_TAG;
}

inline bool is_stack(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == STACK_TAG;
}

inline bool is_string(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == STRING_TAG;
}

inline bool is_large_integer(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == LARGE_INTEGER_TAG;
}

inline bool is_free_list_region(Object* o) {
  return is_heap_object(o) && (HeapObject::cast(o)->class_tag() == FREE_LIST_REGION_TAG ||
                               HeapObject::cast(o)->class_tag() == SINGLE_FREE_WORD_TAG);
}

inline bool is_promoted_track(Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->class_tag() == PROMOTED_TRACK_TAG;
}

inline HeapObject* Object::unmark() {
  ASSERT(is_marked());
  uword address = reinterpret_cast<uword>(this) >> Object::NON_SMI_TAG_SIZE;
  address = address << Object::NON_SMI_TAG_SIZE;
  HeapObject* result = reinterpret_cast<HeapObject*>(address + Object::HEAP_TAG);
  ASSERT(!result->is_marked());
  return result;
}

inline Error* Error::from(String* string) {
  return reinterpret_cast<Error*>(string->mark());
}

inline String* Error::as_string() {
  return String::cast(unmark());
}


} // namespace toit

// Copyright (C) 2023 Toitware ApS.
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
INLINE bool is_smi(const Object* o);
INLINE bool is_heap_object(const Object* o);
INLINE bool is_double(const Object* o);
INLINE bool is_task(const Object* o);
INLINE bool is_instance(const Object* o);
INLINE bool is_array(const Object* o);
INLINE bool is_byte_array(const Object* o);
INLINE bool is_stack(const Object* o);
INLINE bool is_string(const Object* o);
INLINE bool is_large_integer(const Object* o);
INLINE bool is_free_list_region(const Object* o);
INLINE bool is_promoted_track(const Object* o);

class Object {
 public:
  static const int SMI_TAG_SIZE = 1;
  static const uword SMI_TAG_MASK = (1 << SMI_TAG_SIZE) - 1;
  static const uword SMI_TAG = 0;

  static const word NON_SMI_TAG_OFFSET = 0;
  static const int NON_SMI_TAG_SIZE = 2;
  static const uword NON_SMI_TAG_MASK = (1 << NON_SMI_TAG_SIZE) - 1;
  static const uword HEAP_TAG = 0x1;
  static const uword MARKED_TAG = 0x3;

  static Object* cast(Object* obj) { return obj; }

  // Tells whether this is a temporary marked heap object.
  bool is_marked() {
    return (reinterpret_cast<uword>(this) & Object::NON_SMI_TAG_MASK) == MARKED_TAG;
  }

  INLINE HeapObject* unmark();

  // Primitive support that sets content and length iff receiver is String or ByteArray.
  // Returns whether the content and length are set.
  bool byte_content(Program* program, const uint8** content, word* length, BlobKind strings_only) const;

  // Same as above, but with a blob.
  bool byte_content(Program* program, Blob* blob, BlobKind strings_only) const;

  // Primitive support that sets content and length iff receiver is a ByteArray.
  // Returns whether the content and length are set.  If it returns false, the
  // 'error' indicates the reason.  Most likely this is either a type error or
  // the function tried to allocate a ByteArray (for making a CowByteArray
  // mutable), but failed due to out-of-memory.
  bool mutable_byte_content(Process* process, uint8** content, word* length, Error** error);

  // Same as above, but with a blob.
  bool mutable_byte_content(Process* process, MutableBlob* blob, Error** error);

  // Encode this object using the encoder
  bool encode_on(ProgramOrientedEncoder* encoder);
};

// A struct that is only used to get a different overload of the constructor.
struct uninitialized_t {};

// A class that combines a memory address with the size of it.
class Blob {
 public:
  inline Blob(uninitialized_t& u) {}
  inline Blob() : address_(null), length_(0) {}
  Blob(const uint8* address, word length)
      : address_(address), length_(length) {}

  const uint8* address() const { return address_; }
  word length() const { return length_; }

  bool slow_equals(const char* c_string) const;

 private:
  const uint8* address_;
  word length_;
};

// A class that combines a memory address with the size of it.
// Same as `Blob` but the mutable version of it.
class MutableBlob {
 public:
  MutableBlob() : address_(null), length_(0) {}
  MutableBlob(uint8* address, word length)
      : address_(address), length_(length) {}

  uint8* address() { return address_; }
  word length() { return length_; }

 private:
  uint8* address_;
  word length_;
};

// An error is a temporary object (a tagged string) only used for signaling a primitive has failed.
class Error : public Object {
 public:
  static INLINE Error* from(String* string);
  INLINE String* as_string();
  // Errors are tagged with binary 11 in the low bits.
  // Within primitives, errors are sometimes represented as small integers,
  // which are shifted indices into the program roots.
  static const int ERROR_SHIFT = 2;
  static const uword ERROR_TAG = 3;
  static const int MAX_TAGGED_ERROR = 256;
};

class Smi : public Object {
 public:
  static word value(Smi* smi) {
    return reinterpret_cast<word>(smi) >> SMI_TAG_SIZE;
  }

  static word value(Object* object) {
    ASSERT(is_smi(object));
    return reinterpret_cast<word>(object) >> SMI_TAG_SIZE;
  }

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

  static Smi* cast(Object* object) {
    ASSERT(is_smi(object));
    return static_cast<Smi*>(object);
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
  virtual void do_roots(Object** roots, word length) = 0;
  virtual bool shrink_stacks() const { return false; }
  virtual bool skip_marking(HeapObject* object) const { return false; }
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
  INLINE Smi* header() const {
    Object* result = _at(HEADER_OFFSET);
    ASSERT(is_smi(result));
    return Smi::cast(result);
  }
  INLINE Smi* class_id() const {
    return Smi::from((Smi::value(header()) >> HeapObject::CLASS_ID_OFFSET) & HeapObject::CLASS_ID_MASK);
  }
  INLINE TypeTag class_tag() const {
    return static_cast<TypeTag>((Smi::value(header()) >> HeapObject::CLASS_TAG_OFFSET) & HeapObject::CLASS_TAG_MASK);
  }
  INLINE bool has_class_tag(TypeTag tag) const {
    uword header_word = reinterpret_cast<uword>(header());
    uword tag_word = static_cast<uword>(tag);
    int shift = HeapObject::CLASS_TAG_OFFSET + SMI_TAG_SIZE;
    uword mask = HeapObject::CLASS_TAG_MASK << shift;
    return (header_word & mask) == (tag_word << shift);
  }
  INLINE bool has_active_finalizer() const {
    const HeapObject* self = this;
    if (has_forwarding_address()) {
      self = forwarding_address();
    }
    return (Smi::value(self->header()) & (1 << HeapObject::FINALIZER_BIT_OFFSET)) != 0;
  }
  INLINE void set_has_active_finalizer() {
    ASSERT(!has_forwarding_address());
    uword header_word = Smi::value(header());
    header_word |= 1 << HeapObject::FINALIZER_BIT_OFFSET;
    _set_header(Smi::from(header_word));
  }
  INLINE void clear_has_active_finalizer() {
    ASSERT(!has_forwarding_address());
    uword header_word = Smi::value(header());
    header_word &= ~(1 << HeapObject::FINALIZER_BIT_OFFSET);
    _set_header(Smi::from(header_word));
  }

  INLINE bool has_forwarding_address() const {
    return is_heap_object(_at(HEADER_OFFSET));
  }

  // During GC the header can be a heap object (a forwarding pointer).
  INLINE HeapObject* forwarding_address() const {
    ASSERT(has_forwarding_address());
    return HeapObject::cast(_at(HEADER_OFFSET));
  }

  INLINE void set_forwarding_address(HeapObject* destination) {
    _at_put(HEADER_OFFSET, destination);
  }

  // For asserts.  The remembered set is a card marking scheme, so it may
  // return true when neighbouring objects are in the set.  Always returns true
  // for objects in the new-space.
  bool in_remembered_set() const;

  // Pseudo virtual member functions.
  word size(Program* program) const;  // Returns the byte size of this object.
  void roots_do(Program* program, RootCallback* cb);  // For GC.
  void do_pointers(Program* program, PointerCallback* cb);  // For snapshots.

  // The header contains either a Smi that represents the class id/class
  // tag or a HeapObject which is a forwarding pointer during scavenge.
  static const word HEADER_OFFSET = Object::NON_SMI_TAG_OFFSET;

  static const word CLASS_TAG_BIT_SIZE = 4;
  static const word CLASS_TAG_OFFSET = 0;
  static const uword CLASS_TAG_MASK = (1 << CLASS_TAG_BIT_SIZE) - 1;

  static const word FINALIZER_BIT_SIZE = 1;
  static const word FINALIZER_BIT_OFFSET = CLASS_TAG_OFFSET + CLASS_TAG_BIT_SIZE;
  static const uword FINALIZER_BIT_MASK = (1 << FINALIZER_BIT_SIZE) - 1;

  static const word CLASS_ID_BIT_SIZE = 10;
  static const word CLASS_ID_OFFSET = FINALIZER_BIT_OFFSET + FINALIZER_BIT_SIZE;
  // This mask lets class_id() return negative values.  The GC uses
  // negative class ids for on-heap pseudo-objects like free memory.
  static const uword CLASS_ID_MASK = -1;

  static const word SIZE = HEADER_OFFSET + WORD_SIZE;

  // Operations for temporary marking a heap object.
  // Used for returning an error object when a primitive fails and
  // used in the class field to mark a forwarding pointer.
  HeapObject* mark() {
    ASSERT(!is_marked());
    uword raw = reinterpret_cast<uword>(this) | Error::ERROR_TAG;
    HeapObject* result = reinterpret_cast<HeapObject*>(raw);
    ASSERT(result->is_marked());
    return result;
  }

  static HeapObject* cast(Object* obj) {
    ASSERT(is_heap_object(obj));
    return static_cast<HeapObject*>(obj);
  }

  static const HeapObject* cast(const Object* obj) {
    ASSERT(is_heap_object(obj));
    return static_cast<const HeapObject*>(obj);
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

  // Returns true for objects that can have a Toit-level finalizer added.
  // Immortal objects with no identity like integers and strings cannot
  // have Toit-level finalizers.  (External byte arrays and strings can
  // have VM finalizers though.)
  bool can_be_toit_finalized(Program* program) const;

  inline bool on_program_heap(Process* process) const;

  static word allocation_size() { return _align(SIZE); }
  static void allocation_size(int* word_count, int* extra_bytes) {
    *word_count = SIZE / WORD_SIZE;
    *extra_bytes = 0;
  }

  // Not very fast - used for asserts.
  bool contains_pointers_to(Program* program, Space* space);

  bool is_a_free_object();

 protected:
  void _set_header(Smi* class_id, TypeTag class_tag) {
    uword header = Smi::value(class_id);
    header = (header << CLASS_ID_OFFSET) | class_tag;

    _set_header(Smi::from(header));
    ASSERT(this->class_id() == class_id);
    ASSERT(this->has_class_tag(class_tag));
  }

  INLINE void _set_header(Smi* header){
    _at_put(HEADER_OFFSET, header);
  }

  void _set_header(Program* program, Smi* id);

  INLINE uword _raw() const { return reinterpret_cast<uword>(this) - HEAP_TAG; }
  INLINE uword* _raw_at() { return reinterpret_cast<uword*>(reinterpret_cast<uword>(this) - HEAP_TAG); }
  INLINE uword* _raw_at(word offset) { return reinterpret_cast<uword*>(reinterpret_cast<uword>(this) - HEAP_TAG + offset); }
  INLINE const uword* _raw_at() const { return reinterpret_cast<const uword*>(reinterpret_cast<uword>(this) - HEAP_TAG); }
  INLINE const uword* _raw_at(word offset) const { return reinterpret_cast<const uword*>(reinterpret_cast<uword>(this) - HEAP_TAG + offset); }

  INLINE Object* _at(word offset) const { return reinterpret_cast<Object* const*>(_raw_at())[offset / WORD_SIZE]; }
  INLINE void _at_put(word offset, Object* value) { reinterpret_cast<Object**>(_raw_at())[offset / WORD_SIZE] = value; }
  INLINE Object** _root_at(word offset) { return reinterpret_cast<Object**>(_raw_at()) + offset / WORD_SIZE; }

  INLINE uword _word_at(word offset) const { return _raw_at()[offset / WORD_SIZE]; }
  INLINE void _word_at_put(word offset, uword value) { _raw_at()[offset / WORD_SIZE] = value; }

  INLINE uint8 _byte_at(word offset) const { return reinterpret_cast<const uint8*>(_raw_at())[offset]; }
  INLINE void _byte_at_put(word offset, uint8 value) { reinterpret_cast<uint8*>(_raw_at())[offset] = value; }

  INLINE uhalf_word _half_word_at(word offset) const { return *reinterpret_cast<const uhalf_word*>(_raw_at(offset)); }
  INLINE void _half_word_at_put(word offset, uhalf_word value) { *reinterpret_cast<uhalf_word*>(_raw_at(offset)) = value; }

  INLINE double _double_at(word offset) const { return bit_cast<double>(_int64_at(offset)); }
  INLINE void _double_at_put(word offset, double value) { _int64_at_put(offset, bit_cast<int64>(value)); }

  INLINE int64 _int64_at(word offset) const { return *reinterpret_cast<const int64*>(_raw_at(offset)); }
  INLINE void _int64_at_put(word offset, int64 value) { *reinterpret_cast<int64*>(_raw_at(offset)) = value; }

  static word _align(word byte_size) { return (byte_size + (WORD_SIZE - 1)) & ~(WORD_SIZE - 1); }

  friend class Interpreter;
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
  word length() const { return _word_at(LENGTH_OFFSET); }

  static INLINE word max_length_in_process();
  static INLINE word max_length_in_program();

  // Must match collections.toit.
  static const word ARRAYLET_SIZE = 500;

  INLINE Object* at(word index) const {
    ASSERT(index >= 0 && index < length());
    return _at(_offset_from(index));
  }

  INLINE void at_put(word index, Smi* value) {
    ASSERT(index >= 0 && index < length());
    _at_put(_offset_from(index), value);
  }

  INLINE void at_put(word index, Object* value);

  INLINE void at_put_no_write_barrier(word index, Object* value) {
    ASSERT(index >= 0 && index < length());
    _at_put(_offset_from(index), value);
  }

  void copy_from(Array* other, word length) {
    memcpy(content(), other->content(), length * WORD_SIZE);
  }

  uint8* content() { return reinterpret_cast<uint8*>(_raw() + _offset_from(0)); }

  word size() const { return allocation_size(length()); }

  void roots_do(RootCallback* cb);

#ifndef TOIT_FREERTOS
  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st, word length);
#endif

  static Array* cast(Object* array) {
     ASSERT(is_array(array));
     return static_cast<Array*>(array);
  }

  static const Array* cast(const Object* array) {
     ASSERT(is_array(array));
     return static_cast<const Array*>(array);
  }

  Object** base() { return reinterpret_cast<Object**>(_raw_at(_offset_from(0))); }

  static word allocation_size(word length) { return  _align(_offset_from(length)); }

  static void allocation_size(word length, int* word_count, int* extra_bytes) {
    *word_count = HEADER_SIZE / WORD_SIZE + length;
    *extra_bytes = 0;
  }

  void fill(word from, Object* filler);

 private:
  static const word LENGTH_OFFSET = HeapObject::SIZE;
  static const word HEADER_SIZE = LENGTH_OFFSET + WORD_SIZE;

  void _set_length(word value) { _word_at_put(LENGTH_OFFSET, value); }

  // Can only be called on newly allocated objects that will be either
  // in new-space or were added to the remembered set on creation.
  // Is also called from the compiler, where there are no write barriers.
  void _initialize_no_write_barrier(word length, Object* filler) {
    _set_length(length);
    for (word index = 0; index < length; index++) {
      at_put_no_write_barrier(index, filler);
    }
  }

  void _initialize(word length) {
    _set_length(length);
  }

  friend class ObjectHeap;
  friend class ProgramHeap;

 protected:
  static word _offset_from(word index) { return HEADER_SIZE + index * WORD_SIZE; }
};


class ByteArray : public HeapObject {
 public:
  // Abstraction to access the content of a ByteArray.
  // Note that a ByteArray can have two representations.
  class Bytes {
   public:
    explicit Bytes(ByteArray* array) {
      word l = array->raw_length();
      if (l >= 0) {
        address_ = array->content();
        length_ = l;
      } else {
        address_ = array->as_external();
        length_ = -1 -l;
      }
      ASSERT(length() >= 0);
    }
    Bytes(uint8* address, const word length) : address_(address), length_(length) {}

    uint8* address() { return address_; }
    word length() { return length_; }

    uint8 at(word index) {
      ASSERT(index >= 0 && index < length());
      return *(address() + index);
    }

    void at_put(word index, uint8 value) {
      ASSERT(index >= 0 && index < length());
      *(address() + index) = value;
    }

    bool is_valid_index(word index) {
      return index >= 0 && index < length();
    }

   private:
    uint8* address_;
    word length_;
  };

  class ConstBytes {
   public:
    explicit ConstBytes(const ByteArray* array) {
      word l = array->raw_length();
      if (l >= 0) {
        address_ = array->content();
        length_ = l;
      } else {
        address_ = array->as_external();
        length_ = -1 -l;
      }
      ASSERT(length() >= 0);
    }
    ConstBytes(const uint8* address, const word length) : address_(address), length_(length) {}

    const uint8* address() { return address_; }
    word length() { return length_; }

   private:
    const uint8* address_;
    word length_;
  };


  bool has_external_address() const { return raw_length() < 0; }

  template<typename T> T* as_external();

  static inline word max_internal_size_in_process();
  static inline word max_internal_size_in_program();
  static word max_internal_size();

  uint8* as_external() {
    ASSERT(external_tag() == RawByteTag || external_tag() == NullStructTag);
    if (has_external_address()) return unsigned_cast(_external_address());
    return 0;
  }

  const uint8* as_external() const {
    ASSERT(external_tag() == RawByteTag || external_tag() == NullStructTag);
    if (has_external_address()) return unsigned_cast(_external_address());
    return 0;
  }

  word size() const {
    return has_external_address()
         ? external_allocation_size()
         : internal_allocation_size(raw_length());
  }

  static word external_allocation_size() {
    return EXTERNAL_SIZE;
  }
  static void external_allocation_size(int* word_count, int* extra_bytes) {
    *word_count = EXTERNAL_SIZE / WORD_SIZE;
    *extra_bytes = 0;
  }

  static word internal_allocation_size(word raw_length) {
    ASSERT(raw_length >= 0);
    return _align(_offset_from(raw_length));
  }

  static void internal_allocation_size(word raw_length, int* word_count, int* extra_bytes) {
    ASSERT(raw_length >= 0);
    *word_count = HEADER_SIZE / WORD_SIZE;
    *extra_bytes = raw_length;
  }

#ifndef TOIT_FREERTOS
  static void snapshot_allocation_size(word length, int* word_count, int* extra_bytes) {
    if (length > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
      return external_allocation_size(word_count, extra_bytes);
    } else {
      return internal_allocation_size(length, word_count, extra_bytes);
    }
  }

  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st, word byte_length);
#endif

  static ByteArray* cast(Object* byte_array) {
     ASSERT(is_byte_array(byte_array));
     return static_cast<ByteArray*>(byte_array);
  }

  static const ByteArray* cast(const Object* byte_array) {
     ASSERT(is_byte_array(byte_array));
     return static_cast<const ByteArray*>(byte_array);
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

  void set_external_address(word length, uint8* value) {
    _initialize_external_memory(length, value, false);
  }

  void clear_external_address() {
    _set_external_address(null);
  }

  uint8* neuter(Process* process);

  word external_tag() const {
    ASSERT(has_external_address());
    return _word_at(EXTERNAL_TAG_OFFSET);
  }

  void do_pointers(PointerCallback* cb);

 private:
  word raw_length() const { return _word_at(LENGTH_OFFSET); }
  uint8* content() { return reinterpret_cast<uint8*>(_raw() + _offset_from(0)); }
  const uint8* content() const { return reinterpret_cast<const uint8*>(_raw() + _offset_from(0)); }

  static const word LENGTH_OFFSET = HeapObject::SIZE;
  static const word HEADER_SIZE = LENGTH_OFFSET + WORD_SIZE;

  // Constants for external representation.
  static const word EXTERNAL_ADDRESS_OFFSET = HEADER_SIZE;
  static_assert(EXTERNAL_ADDRESS_OFFSET % WORD_SIZE == 0, "External pointer not word aligned");
  static const word EXTERNAL_TAG_OFFSET = EXTERNAL_ADDRESS_OFFSET + WORD_SIZE;
  static const word EXTERNAL_SIZE = EXTERNAL_TAG_OFFSET + WORD_SIZE;

  // Any byte-array that is bigger than this size is snapshotted as external
  // byte array.
  static const word SNAPSHOT_INTERNAL_SIZE_CUTOFF = TOIT_PAGE_SIZE_32 >> 2;

  uint8* _external_address() const {
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

  void _set_length(word value) { _word_at_put(LENGTH_OFFSET, value); }

  void _set_external_length(word length) { _set_length(-1 - length); }

  word _external_length() {
    ASSERT(has_external_address());
    return -1 - raw_length();
  }

  void _clear() {
    Bytes bytes(this);
    memset(bytes.address(), 0, bytes.length());
  }

  void _initialize(word length) {
    _set_length(length);
    _clear();
  }

  void _initialize_external_memory(word length, uint8* external_address, bool clear_content = true) {
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
  friend class VmFinalizerNode;

 protected:
  static word _offset_from(word index) {
    ASSERT(index >= 0);
    ASSERT(index <= max_internal_size());
    return HEADER_SIZE + index;
  }

 public:
  // Constants that should be elsewhere.
  static const word MIN_IO_BUFFER_SIZE = 1;
  // Selected to be able to contain most MTUs (1500), but still align to 512 bytes.
  static const word PREFERRED_IO_BUFFER_SIZE = 1536 - HEADER_SIZE;
};


class LargeInteger : public HeapObject {
 public:
  int64 value() { return _int64_at(VALUE_OFFSET); }

  static LargeInteger* cast(Object* value) {
     ASSERT(is_large_integer(value));
     return static_cast<LargeInteger*>(value);
  }

  static const LargeInteger* cast(const Object* value) {
     ASSERT(is_large_integer(value));
     return static_cast<const LargeInteger*>(value);
  }

  static word allocation_size() { return SIZE; }
  static void allocation_size(int* word_count, int* extra_bytes) {
    *word_count = HeapObject::SIZE / WORD_SIZE;
    *extra_bytes = 8;
  }

 private:
  static const word VALUE_OFFSET = HeapObject::SIZE;
  static const word SIZE = VALUE_OFFSET + INT64_SIZE;

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
  virtual void do_frame(Stack* frame, int number, int absolute_bci) {}
};


class Method {
 public:
  Method(List<uint8> all_bytes, word offset) : Method(&all_bytes[offset]) {}
  explicit Method(uint8* bytes) : bytes_(bytes) {}

  static Method invalid() { return Method(null); }
  static word allocation_size(word bytecode_size, word max_height) {
    return HEADER_SIZE + bytecode_size;
  }

  bool is_valid() const { return bytes_ != null; }

  bool is_normal_method() const { return kind_() == METHOD; }
  bool is_field_accessor() const { return kind_() == FIELD_ACCESSOR; }
  bool is_lambda_method() const { return kind_() == LAMBDA; }
  bool is_block_method() const { return  kind_() == BLOCK; }

  int arity() const { return bytes_[ARITY_OFFSET]; }
  int captured_count() const { return value_(); }
  int selector_offset() const { return value_(); }
  uint8* entry() const { return &bytes_[ENTRY_OFFSET]; }
  int max_height() const { return (bytes_[KIND_HEIGHT_OFFSET] >> KIND_BITS) * 4; }

  uint8* bcp_from_bci(word bci) const { return &bytes_[ENTRY_OFFSET + bci]; }
  uint8* header_bcp() const { return bytes_; }

  static word entry_offset() { return ENTRY_OFFSET; }
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
  static const word ARITY_OFFSET = 0;
  static const word KIND_HEIGHT_OFFSET = ARITY_OFFSET + BYTE_SIZE;
  static const word KIND_BITS = 2;
  static const word KIND_MASK = (1 << KIND_BITS) - 1;
  static const word HEIGHT_BITS = 8 - KIND_BITS;
  static const word VALUE_OFFSET = KIND_HEIGHT_OFFSET + BYTE_SIZE;
  static const word ENTRY_OFFSET = VALUE_OFFSET + 2;
  static const word HEADER_SIZE = ENTRY_OFFSET;

  uint8* bytes_;

  enum Kind { METHOD = 0, FIELD_ACCESSOR, LAMBDA, BLOCK };

  Kind kind_() const { return static_cast<Kind>(bytes_[KIND_HEIGHT_OFFSET] & KIND_MASK); }

  void _initialize(Kind kind, int value, int arity, List<uint8> bytecodes, int max_height) {
    ASSERT(0 <= arity && arity < (1 <<  BYTE_BIT_SIZE));
    _set_kind_height(kind, max_height);
    _set_arity(arity);
    _set_value(value);
    _set_bytecodes(bytecodes);

    ASSERT(this->kind_()  == kind);
    ASSERT(this->arity()  == arity);
    ASSERT(this->value_() == value);
  }

  int _int16_at(word offset) const {
    int16 result;
    memcpy(&result, &bytes_[offset], 2);
    return result;
  }

  void _set_int16_at(word offset, int value) {
    int16 source = value;
    memcpy(&bytes_[offset], &source, 2);
  }

  int value_() const { return _int16_at(VALUE_OFFSET); }
  void _set_value(int value) { _set_int16_at(VALUE_OFFSET, value); }

  void _set_arity(int arity) {
    ASSERT(arity <= 0xFF);
    bytes_[ARITY_OFFSET] = arity;
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
    bytes_[KIND_HEIGHT_OFFSET] = kind | encoded_height;
  }
  void _set_captured_count(int value) { _set_value(value); }
  void _set_selector_offset(int value) { _set_value(value); }
  void _set_bytecodes(List<uint8> bytecodes) {
    if (bytecodes.length() > 0) {
      memcpy(&bytes_[ENTRY_OFFSET], bytecodes.data(), bytecodes.length());
    }
  }
};


class Stack : public HeapObject {
 public:
  word length() const { return _word_at(LENGTH_OFFSET); }
  word top() const { return _word_at(TOP_OFFSET); }
  word try_top() const { return _word_at(TRY_TOP_OFFSET); }
  word absolute_bci_at_preemption(Program* program);

  // We keep track of a single method that we have invoked, but where the
  // check for stack overflow and any necessary growth of the stack hasn't
  // been taken care of, because we got interrupted by preemption. The
  // interpreter checks this field when it resumes execution on a stack,
  // so we are sure that there is enough stack space available for the
  // already invoked method.
  Method pending_stack_check_method() const {
    uword pending = _word_at(PENDING_STACK_CHECK_METHOD_OFFSET);
    return Method(reinterpret_cast<uint8*>(pending));
  }

  void set_pending_stack_check_method(Method method) {
    uword bcp = reinterpret_cast<uword>(method.header_bcp());
    _word_at_put(PENDING_STACK_CHECK_METHOD_OFFSET, bcp);
  }

  void transfer_to_interpreter(Interpreter* interpreter);
  void transfer_from_interpreter(Interpreter* interpreter);

  word size() const { return allocation_size(length()); }

  void copy_to(Stack* other);

  void roots_do(Program* program, RootCallback* cb);

  // Iterates over all frames on this stack and returns the number of frames.
  int frames_do(Program* program, FrameCallback* cb);

  static INLINE word initial_length() { return 64; }
  static INLINE word max_length();

  static Stack* cast(Object* stack) {
    ASSERT(is_stack(stack));
    return static_cast<Stack*>(stack);
  }

  static const Stack* cast(const Object* stack) {
    ASSERT(is_stack(stack));
    return static_cast<const Stack*>(stack);
  }

  static word allocation_size(word length) { return  _align(HEADER_SIZE + length * WORD_SIZE); }
  static void allocation_size(word length, int* word_count, int* extra_bytes) {
    ASSERT(length > 0);
    *word_count = HEADER_SIZE / WORD_SIZE + length;
    *extra_bytes = 0;
  }

 private:
  // We keep a 'guard zone' of words that must not be touched right after
  // the header of the stack object. The stack grows downwards towards lower
  // addresses. If the stack overflows into the guard zone we will catch the
  // issue when enter or leave the interpreter - or when we transfer control
  // between tasks.
#ifdef BUILD_32
  static const uword GUARD_ZONE_MARKER = 0xcaadabe7;
#elif BUILD_64
  static const uword GUARD_ZONE_MARKER = 0x7eb91112caadabe7;
#endif
#ifdef DEBUG
  static const word GUARD_ZONE_WORDS = 8;
#else
  // TODO(kasper): We do not want to pay for the guard zone in deployments,
  // so we should keep the zone empty there after a bit of testing..
  static const word GUARD_ZONE_WORDS = 4;
#endif
  static const word GUARD_ZONE_SIZE = GUARD_ZONE_WORDS * WORD_SIZE;

  static const word LENGTH_OFFSET = HeapObject::SIZE + WORD_SIZE;
  static const word TOP_OFFSET = LENGTH_OFFSET + WORD_SIZE;
  static const word TRY_TOP_OFFSET = TOP_OFFSET + WORD_SIZE;
  static const word PENDING_STACK_CHECK_METHOD_OFFSET = TRY_TOP_OFFSET + WORD_SIZE;
  static const word GUARD_ZONE_OFFSET = PENDING_STACK_CHECK_METHOD_OFFSET + WORD_SIZE;
  static const word HEADER_SIZE = GUARD_ZONE_OFFSET + GUARD_ZONE_SIZE;

  void _set_length(word value) { _word_at_put(LENGTH_OFFSET, value); }
  void _set_top(word value) { _word_at_put(TOP_OFFSET, value); }
  void _set_try_top(word value) { _word_at_put(TRY_TOP_OFFSET, value); }

  void _initialize(word length) {
    _set_length(length);
    _set_top(length);
    _set_try_top(length);
    set_pending_stack_check_method(Method::invalid());
    for (word i = 0; i < GUARD_ZONE_WORDS; i++) {
      *guard_zone_address(i) = GUARD_ZONE_MARKER;
    }
  }

  bool is_guard_zone_touched() {
    for (word i = 0; i < GUARD_ZONE_WORDS; i++) {
      if (*guard_zone_address(i) != GUARD_ZONE_MARKER) return true;
    }
    return false;
  }

  uword* guard_zone_address(word index) {
    ASSERT(index >= 0 && index < GUARD_ZONE_WORDS);
    return _raw_at(GUARD_ZONE_OFFSET + index * WORD_SIZE);
  }

  Object** _stack_base_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(length()))); }
  Object** _stack_limit_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(0))); }
  Object** _stack_sp_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(top()))); }
  Object** _stack_try_sp_addr() { return reinterpret_cast<Object**>(_raw_at(_array_offset_from(try_top()))); }

  Object* at(word index) {
    ASSERT((_stack_sp_addr() + index) < _stack_base_addr());
    return *(_stack_sp_addr() + index);
  }

  Object** _from_block(Smi* block) {
    return _stack_base_addr() - (Smi::value(block) - BLOCK_SALT);
  }

  Smi* _to_block(Object** pointer) {
    return Smi::from(_stack_base_addr() - pointer + BLOCK_SALT);
  }

  bool is_inside(Object** value) {
    return (_stack_base_addr() > value) && (value >= _stack_sp_addr());
  }

  uword* _array_address(word index) { return _raw_at(_array_offset_from(index)); }
  static word _array_offset_from(word index) { return HEADER_SIZE + index  * WORD_SIZE; }

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

  static word allocation_size() { return SIZE; }
  static void allocation_size(int* word_count, int* extra_bytes) {
    *word_count = HeapObject::SIZE / WORD_SIZE;
    *extra_bytes = 8;
  }

 private:
  static const word VALUE_OFFSET = HeapObject::SIZE;
  static const word SIZE = VALUE_OFFSET + DOUBLE_SIZE;

  void _initialize(double value) { _set_value(value); }
  void _set_value(double value) { _double_at_put(VALUE_OFFSET, value); }

  friend class Interpreter;
  friend class ObjectHeap;
  friend class ProgramHeap;
};

class String : public HeapObject {
 public:
  uint16 hash_code() {
    word result = _raw_hash_code();
    return result != NO_HASH_CODE ? result : _assign_hash_code();
  }

  word length() const {
     word result = _internal_length();
     return result != SENTINEL ? result : _external_length();
  }

  // Tells whether the string content is on the heap or external.
  bool content_on_heap() const { return _internal_length() != SENTINEL; }

  static INLINE word max_length_in_process();
  static INLINE word max_length_in_program();

  bool is_empty() { return length() == 0; }

  word size() const {
    word len = _internal_length();
    if (len != SENTINEL) return internal_allocation_size(length());
    return external_allocation_size();
  }

  bool equals(Object* other);
  bool slow_equals(const char* string, word string_length);
  bool slow_equals(const char* string);
  static bool slow_equals(const char* string_a, word length_a, const char* string_b, word length_b) {
    return length_a == length_b && memcmp(string_a, string_b, length_a) == 0;
  }
  static bool slow_equals(const uint8* bytes_a, word length_a, const uint8* bytes_b, word length_b) {
    return length_a == length_b && memcmp(bytes_a, bytes_b, length_a) == 0;
  }

  bool starts_with_vowel();

  // Returns -1, 0, or 1.
  int compare(String* other);
  static word compare(const char* string_a, word length_a, const char* string_b, word length_b) {
    word min_len;
    word equal_result;
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
  static word compare(const uint8* bytes_a, word length_a, const uint8* bytes_b, word length_b) {
    return compare(reinterpret_cast<const char*>(bytes_a),
                   length_a,
                   reinterpret_cast<const char*>(bytes_b),
                   length_b);
  }

  uint16 compute_hash_code();
  static uint16 compute_hash_code_for(const char* str, word str_len);
  static uint16 compute_hash_code_for(const char* str);

#ifndef TOIT_FREERTOS
  void write_content(SnapshotWriter* st);
  void read_content(SnapshotReader* st, word length);
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

  static const String* cast(const Object* object) {
     ASSERT(is_string(object));
     return static_cast<const String*>(object);
  }

  static inline word max_internal_size_in_process();
  static inline word max_internal_size_in_program();
  static word max_internal_size();

  static word internal_allocation_size(word length) {
    return _align(_offset_from(length+1));
  }
  static void internal_allocation_size(word length, int* word_count, int* extra_bytes) {
    ASSERT(length <= max_internal_size());
    // The length and hash-code are stored as half-word sizes.
    static_assert(INTERNAL_HEADER_SIZE == HeapObject::SIZE + 2 * HALF_WORD_SIZE,
                  "Unexpected string layout");
    *word_count = HeapObject::SIZE / WORD_SIZE;
    *extra_bytes = length + OVERHEAD - HeapObject::SIZE;
  }

  static word external_allocation_size() { return _align(EXTERNAL_OBJECT_SIZE); }
  static void external_allocation_size(int* word_count, int* extra_bytes) {
    *word_count = external_allocation_size() / WORD_SIZE;
    *extra_bytes = 0;
  }

#ifndef TOIT_FREERTOS
  static void snapshot_allocation_size(word length, int* word_count, int* extra_bytes) {
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
    explicit Bytes(const String* string) {
      word len = string->_internal_length();
      if (len != SENTINEL) {
        address_ = string->_as_utf8bytes();
        length_ = len;
      } else {
        address_ = string->as_external();
        length_ = string->_external_length();
      }
      ASSERT(length() >= 0);
    }
    Bytes(const uint8* address, const word length) : address_(address), length_(length) {}

    const uint8* address() { return address_; }
    word length() { return length_; }

    uint8 at(word index) {
      ASSERT(index >= 0 && index < length());
      return *(address() + index);
    }

    bool is_valid_index(word index) {
      return index >= 0 && index < length();
    }

   private:
    const uint8* address_;
    word length_;
  };

  class MutableBytes {
   public:
    explicit MutableBytes(String* string) {
      word len = string->_internal_length();
      if (len != SENTINEL) {
        address_ = string->_as_utf8bytes();
        length_ = len;
      } else {
        address_ = string->as_external();
        length_ = string->_external_length();
      }
      ASSERT(length() >= 0);
    }

    uint8* address() { return address_; }
    word length() { return length_; }

    void _initialize(const char* str) {
      memcpy(address(), str, length());
    }

    void _initialize(word index, String* other, word start, word length) {
      Bytes ot(other);
      memcpy(address() + index, ot.address() + start, length);
    }

    void _initialize(word index, const uint8* chars, word start, word length) {
      memcpy(address() + index, chars + start, length);
    }

    void _at_put(word index, uint8 value) {
      ASSERT(index >= 0 && index < length());
      *(address() + index) = value;
    }

    // Set zero at end to make content C look alike.
    void _set_end() {
      *(address() + length()) = 0;
    }

    bool is_valid_index(word index) {
      return index >= 0 && index < length();
    }

   private:
    uint8* address_;
    word length_;
  };

 private:
  // Two representations
  // in heap content:  [class:w][hash_code:h][length:h][content:byte*length][0][padding]
  // off heap content: [class:w][hash_code:h][-1:h]    [length:w][external_address:w]
  // The first length field will also be used or tagging, recognizing an external representation.
  // Please note that if need be it is easy to extend the width of hash_code for strings with off heap content.
  static const word SENTINEL = 65535;
  static_assert(SENTINEL > TOIT_PAGE_SIZE, "Sentinel must not be legal internal length");
  static const word HASH_CODE_OFFSET = HeapObject::SIZE;
  static const word INTERNAL_LENGTH_OFFSET = HASH_CODE_OFFSET + HALF_WORD_SIZE;
  static const word INTERNAL_HEADER_SIZE = INTERNAL_LENGTH_OFFSET + HALF_WORD_SIZE;
  static const word OVERHEAD = INTERNAL_HEADER_SIZE + 1;
  static const uint16 NO_HASH_CODE = 0xFFFF;

  static const word EXTERNAL_LENGTH_OFFSET = INTERNAL_HEADER_SIZE;
  static const word EXTERNAL_ADDRESS_OFFSET = EXTERNAL_LENGTH_OFFSET + WORD_SIZE;
  static_assert(EXTERNAL_ADDRESS_OFFSET % WORD_SIZE == 0, "External pointer not word aligned");
  static const word EXTERNAL_OBJECT_SIZE = EXTERNAL_ADDRESS_OFFSET + WORD_SIZE;

  // Any string that is bigger than this size is snapshotted as external string.
  static const word SNAPSHOT_INTERNAL_SIZE_CUTOFF = TOIT_PAGE_SIZE_32 >> 2;

  uint16 _raw_hash_code() const { return _half_word_at(HASH_CODE_OFFSET); }
  void _raw_set_hash_code(uint16 value) { _half_word_at_put(HASH_CODE_OFFSET, value); }
  void _set_length(word value) { _half_word_at_put(INTERNAL_LENGTH_OFFSET, value); }

  static word _offset_from(word index) {
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

  const uint8* _as_utf8bytes() const {
    if (content_on_heap()) {
      return reinterpret_cast<const uint8*>(_raw_at(INTERNAL_HEADER_SIZE));
    }
    return _external_address();
  }

  word _internal_length() const {
     return _half_word_at(INTERNAL_LENGTH_OFFSET);
  }

  word _external_length() const {
     ASSERT(_internal_length() == SENTINEL);
     return _word_at(EXTERNAL_LENGTH_OFFSET);
  }

  void _set_external_length(word value) {
    _set_length(SENTINEL);
    _word_at_put(EXTERNAL_LENGTH_OFFSET, value);
  }

  uint8* as_external() {
    if (!content_on_heap()) return unsigned_cast(_external_address());
    return null;
  }

  const uint8* as_external() const {
    if (!content_on_heap()) return unsigned_cast(_external_address());
    return null;
  }

  void clear_external_address() {
    _set_external_address(null);
  }

  uint8* _external_address() const {
    return reinterpret_cast<uint8*>(_word_at(EXTERNAL_ADDRESS_OFFSET));
  }

  void _set_external_address(const uint8* value) {
    ASSERT(!content_on_heap());
    _word_at_put(EXTERNAL_ADDRESS_OFFSET, reinterpret_cast<word>(value));
  }

  bool _is_valid_utf8();

  friend class ObjectHeap;
  friend class ProgramHeap;
  friend class VmFinalizerNode;
};


class Instance : public HeapObject {
 public:
  Object* at(word index) const {
    return _at(_offset_from(index));
  }

  INLINE void at_put(word index, Smi* value) {
    _at_put(_offset_from(index), value);
  }

  INLINE Object** root_at(word index) {
    return _root_at(_offset_from(index));
  }

  void at_put_no_write_barrier(word index, Object* value) {
    _at_put(_offset_from(index), value);
  }

  // Using this from the compiler will cause link errors.  Use
  // at_put_no_write_barrier in the compiler instead.
  void at_put(word index, Object* value);

  void instance_roots_do(word instance_size, RootCallback* cb);

#ifndef TOIT_FREERTOS
  void write_content(word instance_size, SnapshotWriter* st);
  void read_content(SnapshotReader* st);
#endif

  // Returns the number of fields in an instance of the given size.
  static word fields_from_size(word instance_size) {
    return (instance_size - HEADER_SIZE) / WORD_SIZE;
  }

  static Instance* cast(Object* value) {
    ASSERT(is_instance(value) || is_task(value));
    return static_cast<Instance*>(value);
  }

  static const Instance* cast(const Object* value) {
    ASSERT(is_instance(value) || is_task(value));
    return static_cast<const Instance*>(value);
  }

  static word allocation_size(word length) { return  _align(_offset_from(length)); }
  static void allocation_size(word length, int* word_count, int* extra_bytes) {
    *word_count = HEADER_SIZE / WORD_SIZE + length;
    *extra_bytes = 0;
  }

  // Some of the instance types have field offsets that are known both
  // on the native and the Toit side.
  // These numbers must stay synced with the fields in collections.toit.
  static const word MAP_SIZE_INDEX        = 0;
  static const word MAP_SPACES_LEFT_INDEX = 1;
  static const word MAP_INDEX_INDEX       = 2;
  static const word MAP_BACKING_INDEX     = 3;

  static const word LIST_ARRAY_INDEX = 0;
  static const word LIST_SIZE_INDEX  = 1;

  static const word LIST_SLICE_LIST_INDEX = 0;
  static const word LIST_SLICE_FROM_INDEX = 1;
  static const word LIST_SLICE_TO_INDEX   = 2;

  static const word BYTE_ARRAY_COW_BACKING_INDEX    = 0;
  static const word BYTE_ARRAY_COW_IS_MUTABLE_INDEX = 1;

  static const word BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX = 0;
  static const word BYTE_ARRAY_SLICE_FROM_INDEX       = 1;
  static const word BYTE_ARRAY_SLICE_TO_INDEX         = 2;

  static const word LARGE_ARRAY_SIZE_INDEX   = 0;
  static const word LARGE_ARRAY_VECTOR_INDEX = 1;

  static const word STRING_SLICE_STRING_INDEX = 0;
  static const word STRING_SLICE_FROM_INDEX   = 1;
  static const word STRING_SLICE_TO_INDEX     = 2;

  static const word STRING_BYTE_SLICE_STRING_INDEX = 0;
  static const word STRING_BYTE_SLICE_FROM_INDEX   = 1;
  static const word STRING_BYTE_SLICE_TO_INDEX     = 2;

  static const word TOMBSTONE_DISTANCE_INDEX = 0;

 private:
  static const word HEADER_SIZE = HeapObject::SIZE;

  static word _offset_from(uword index) { return HEADER_SIZE + index  * WORD_SIZE; }

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
  uword size() const {
    if (has_class_tag(SINGLE_FREE_WORD_TAG)) return WORD_SIZE;
    ASSERT(has_class_tag(FREE_LIST_REGION_TAG));
    return _word_at(SIZE_OFFSET);
  }

  bool can_be_daisychained() const { return has_class_tag(FREE_LIST_REGION_TAG); }

  void roots_do(word instance_size, RootCallback* cb) {}

  static FreeListRegion* cast(Object* value) {
    ASSERT(is_free_list_region(value));
    return static_cast<FreeListRegion*>(value);
  }

  static const FreeListRegion* cast(const Object* value) {
    ASSERT(is_free_list_region(value));
    return static_cast<const FreeListRegion*>(value);
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
  static const word SIZE_OFFSET = HeapObject::SIZE;
  static const word NEXT_OFFSET = SIZE_OFFSET + WORD_SIZE;
  static const word MINIMUM_SIZE = NEXT_OFFSET + WORD_SIZE;
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
  uword size() const {
    ASSERT(has_class_tag(PROMOTED_TRACK_TAG));
    return end() - _raw();
  }

  // Returns the address of the first object in the track.
  uword start() {
    return _raw() + HEADER_SIZE;
  }

  // When traversing the stack we don't traverse the objects inside the
  // track, so nothing to do here.
  void roots_do(word instance_size, RootCallback* cb) {}

  static PromotedTrack* cast(Object* value) {
    ASSERT(is_promoted_track(value));
    return static_cast<PromotedTrack*>(value);
  }

  static const PromotedTrack* cast(const Object* value) {
    ASSERT(is_promoted_track(value));
    return static_cast<const PromotedTrack*>(value);
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

  uword end() const {
    return _word_at(END_OFFSET);
  }

  // Overwrite the header of the PromotedTrack with free space so that
  // the heap becomes iterable.
  void zap();

  static PromotedTrack* initialize(PromotedTrack* next, uword start, uword end);

  static inline uword header_size() { return HEADER_SIZE; }

 private:
  static const word END_OFFSET = HeapObject::SIZE;
  static const word NEXT_OFFSET = END_OFFSET + WORD_SIZE;
  static const word HEADER_SIZE = NEXT_OFFSET + WORD_SIZE;
};

class Task : public Instance {
 public:
  static const word STACK_INDEX = 0;
  static const word ID_INDEX = STACK_INDEX + 1;

  Stack* stack() { return Stack::cast(at(STACK_INDEX)); }
  void set_stack(Stack* value) { at_put(STACK_INDEX, value); }

  word id() { return Smi::value(at(ID_INDEX)); }

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
  void _initialize(Stack* stack, Smi* id) {
    at_put(ID_INDEX, id);
    set_stack(stack);
  }

  friend class ObjectHeap;
};

inline bool is_smi(const Object* o) {
  return (reinterpret_cast<uword>(o) & Object::SMI_TAG_MASK) == Object::SMI_TAG;
}

inline bool is_heap_object(const Object* o) {
  return (reinterpret_cast<uword>(o) & Object::NON_SMI_TAG_MASK) == Object::HEAP_TAG;
}

inline bool is_double(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(DOUBLE_TAG);
}

inline bool is_task(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(TASK_TAG);
}

inline bool is_instance(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(INSTANCE_TAG);
}

inline bool is_array(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(ARRAY_TAG);
}

inline bool is_byte_array(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(BYTE_ARRAY_TAG);
}

inline bool is_stack(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(STACK_TAG);
}

inline bool is_string(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(STRING_TAG);
}

inline bool is_large_integer(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(LARGE_INTEGER_TAG);
}

inline bool is_free_list_region(const Object* o) {
  return is_heap_object(o) && (HeapObject::cast(o)->has_class_tag(FREE_LIST_REGION_TAG) ||
                               HeapObject::cast(o)->has_class_tag(SINGLE_FREE_WORD_TAG));
}

inline bool is_promoted_track(const Object* o) {
  return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(PROMOTED_TRACK_TAG);
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

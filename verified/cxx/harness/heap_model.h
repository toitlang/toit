// Copyright (C) 2026 Toit contributors.
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

// The heap model of the harnesses: nondeterministic VM objects that satisfy
// exactly what the VM guarantees, and nothing a program controls.
//
// Guaranteed (and therefore assumed here):
//  G1 every heap reference designates a live object whose header (class id
//     and class tag) is valid, allocated with the size the VM computes for
//     it (src/objects.h: aligned to words; strings with their NUL);
//  G2 arrays, byte arrays and strings have the length their header words
//     say, internal or external (raw external memory of that length, V5 of
//     verified/core/TRUSTED.md);
//  G3 an instance of a builtin class has at least the fields
//     VerifierImpl::check_builtin_classes (src/verifier.cc) requires for an
//     accepted program (List_ 2, ListSlice_ 3, Map_ 4, slices 3, COW 2);
//  G4 fields and elements hold smis or references satisfying G1 (heap
//     integrity, TRUSTED.md V2).
// Not assumed (a program controls them): the values of instance fields and
// array elements (sizes, bounds, backings of List_, Map_, slices: any smi or
// any object), the bytes of strings and byte arrays (strings need not be
// valid UTF-8), the class of an object reached through a field.
//
// Bounds: object graphs are trees of depth <= CXXV_DEPTH; arrays have at
// most CXXV_ARRAY elements, blobs at most CXXV_BLOB bytes, instances at
// most CXXV_FIELDS fields beyond the guaranteed ones. Sharing and cycles
// are not generated (the encoders bound nesting; a separate argument).

#pragma once

#include "cxxv.h"

#include <stdlib.h>

namespace cxxv {

using namespace toit;

#ifndef CXXV_DEPTH
#define CXXV_DEPTH 2
#endif
#ifndef CXXV_ARRAY
#define CXXV_ARRAY 3
#endif
#ifndef CXXV_BLOB
#define CXXV_BLOB 4
#endif
#ifndef CXXV_FIELDS
#define CXXV_FIELDS 1
#endif

// A user-defined instance class (not builtin).
static const int USER_CLASS_ID = Program::BUILTIN_CLASS_IDS_COUNT;
static const int CLASS_COUNT = USER_CLASS_ID + 1;

struct World {
  Program* program;
  Process* process;
  uint16 class_bits[CLASS_COUNT];
};

// Word-aligned raw storage of exactly `bytes` bytes (rounded up to words as
// the VM's allocators do), returned as a tagged heap reference.
static inline HeapObject* raw_object(word bytes) {
  word size = (bytes + WORD_SIZE - 1) & ~(WORD_SIZE - 1);
  void* p = malloc(size);
  CXXV_ASSUME(p != null);
  CXXV_ASSUME((reinterpret_cast<uword>(p) & (WORD_SIZE - 1)) == 0);
  return HeapObject::from_address(reinterpret_cast<uword>(p));
}

static inline void set_header(HeapObject* object, int class_id, TypeTag tag) {
  object->_set_header(Smi::from(class_id), tag);
}

static inline Smi* nondet_smi() {
  word value = nondet_word();
  CXXV_ASSUME(Smi::is_valid(value));
  return Smi::from(value);
}

// The minimum field count of the builtin instance classes (G3).
static inline int min_fields(int class_id) {
  switch (class_id) {
    case Program::list_class_id_INDEX: return Instance::LIST_SIZE_INDEX + 1;
    case Program::list_slice_class_id_INDEX: return Instance::LIST_SLICE_TO_INDEX + 1;
    case Program::map_class_id_INDEX: return Instance::MAP_BACKING_INDEX + 1;
    case Program::byte_array_cow_class_id_INDEX: return Instance::BYTE_ARRAY_COW_IS_MUTABLE_INDEX + 1;
    case Program::byte_array_slice_class_id_INDEX: return Instance::BYTE_ARRAY_SLICE_TO_INDEX + 1;
    case Program::string_slice_class_id_INDEX: return Instance::STRING_SLICE_TO_INDEX + 1;
    case Program::string_byte_slice_class_id_INDEX: return Instance::STRING_BYTE_SLICE_TO_INDEX + 1;
    case Program::tombstone_class_id_INDEX: return Instance::TOMBSTONE_DISTANCE_INDEX + 1;
    default: return 0;
  }
}

static inline HeapObject* oddball(int class_id) {
  HeapObject* result = raw_object(HeapObject::SIZE);
  set_header(result, class_id, ODDBALL_TAG);
  return result;
}

// The program and process the code under test reads: builtin class ids
// (class id i is builtin i), the class table, the oddball roots, the
// process' program and policy. Every other field stays nondeterministic.
static inline void make_world(World* world) {
  Program* program = static_cast<Program*>(malloc(sizeof(Program)));
  CXXV_ASSUME(program != null);
  // Straight-line (no loop to unwind): class id i is builtin class i.
  // (src/program.h #undefs its BUILTIN_CLASS_IDS list.)
  static_assert(Program::BUILTIN_CLASS_IDS_COUNT == 23, "update the list below");
  Smi** ids = program->_builtin_class_ids;
  ids[0] = Smi::from(0); ids[1] = Smi::from(1); ids[2] = Smi::from(2); ids[3] = Smi::from(3);
  ids[4] = Smi::from(4); ids[5] = Smi::from(5); ids[6] = Smi::from(6); ids[7] = Smi::from(7);
  ids[8] = Smi::from(8); ids[9] = Smi::from(9); ids[10] = Smi::from(10); ids[11] = Smi::from(11);
  ids[12] = Smi::from(12); ids[13] = Smi::from(13); ids[14] = Smi::from(14); ids[15] = Smi::from(15);
  ids[16] = Smi::from(16); ids[17] = Smi::from(17); ids[18] = Smi::from(18); ids[19] = Smi::from(19);
  ids[20] = Smi::from(20); ids[21] = Smi::from(21); ids[22] = Smi::from(22);
  // The class table: left nondeterministic (uninitialized automatic storage
  // of the caller's World is unconstrained for the tool).
  program->class_bits = List<uint16>(world->class_bits, CLASS_COUNT);
#ifndef CXXV_NO_ODDBALLS  // Every heap object costs: see "Cost" in the write-up.
  program->roots_[Program::null_object_INDEX] = oddball(Program::null_class_id_INDEX);
  program->roots_[Program::true_object_INDEX] = oddball(Program::true_class_id_INDEX);
  program->roots_[Program::false_object_INDEX] = oddball(Program::false_class_id_INDEX);
#endif
  Process* process = static_cast<Process*>(malloc(sizeof(Process)));
  CXXV_ASSUME(process != null);
  process->program_ = program;
  PrimitivePolicy* policy = static_cast<PrimitivePolicy*>(malloc(sizeof(PrimitivePolicy)));
  CXXV_ASSUME(policy != null);
  *const_cast<const PrimitivePolicy**>(&process->policy_) = policy;
  world->program = program;
  world->process = process;
}

static inline Object* nondet_leaf(World* world);
static inline Object* nondet_object(World* world, int depth);

static inline String* nondet_string() {
  word length = nondet_int();
  CXXV_ASSUME(0 <= length && length <= CXXV_BLOB);
  HeapObject* result;
  if (nondet_bool()) {
    result = raw_object(String::INTERNAL_HEADER_SIZE + length + 1);
    set_header(result, Program::string_class_id_INDEX, STRING_TAG);
    String* string = static_cast<String*>(result);
    string->_raw_set_hash_code(nondet_ushort());
    string->_set_length(length);
    uint8* content = reinterpret_cast<uint8*>(string->_raw_at(String::INTERNAL_HEADER_SIZE));
    // The content is malloced memory: unconstrained.
    content[length] = 0;
  } else {
    result = raw_object(String::EXTERNAL_OBJECT_SIZE);
    set_header(result, Program::string_class_id_INDEX, STRING_TAG);
    String* string = static_cast<String*>(result);
    string->_raw_set_hash_code(nondet_ushort());
    string->_set_external_length(length);
    uint8* content = static_cast<uint8*>(malloc(length + 1));
    CXXV_ASSUME(content != null);
    // The content is malloced memory: unconstrained.
    content[length] = 0;
    string->_set_external_address(content);
  }
  return static_cast<String*>(result);
}

static inline ByteArray* nondet_byte_array() {
  word length = nondet_int();
  CXXV_ASSUME(0 <= length && length <= CXXV_BLOB);
  HeapObject* result;
  if (nondet_bool()) {
    result = raw_object(ByteArray::HEADER_SIZE + length);
    set_header(result, Program::byte_array_class_id_INDEX, BYTE_ARRAY_TAG);
    ByteArray* bytes = static_cast<ByteArray*>(result);
    bytes->_set_length(length);
    uint8* content = bytes->content();
    // The content is malloced memory: unconstrained.
  } else {
    result = raw_object(ByteArray::EXTERNAL_SIZE);
    set_header(result, Program::byte_array_class_id_INDEX, BYTE_ARRAY_TAG);
    ByteArray* bytes = static_cast<ByteArray*>(result);
    bytes->_set_external_length(length);
    uint8* content = static_cast<uint8*>(malloc(length == 0 ? 1 : length));
    CXXV_ASSUME(content != null);
    // The content is malloced memory: unconstrained.
    bytes->_set_external_address(content);
    bytes->_set_external_tag(RawByteTag);
  }
  return static_cast<ByteArray*>(result);
}

// A string or byte array, internal or external, of a symbolic length in
// [0, max_length] with unconstrained content (memory from malloc is
// unconstrained for the tool; nothing is written but the string's NUL), and
// no loop: the length may be large without unwinding. Internal objects are
// limited to the VM's internal size limit.
static inline Object* nondet_blob(word max_length) {
  word length = nondet_word();
  CXXV_ASSUME(0 <= length && length <= max_length);
#ifdef CXXV_BLOB_KIND
  // One kind per run (bit 0: string, bit 1: internal): a concrete class tag
  // lets the tool prune the instance cases of the blob decoders.
  bool is_string = (CXXV_BLOB_KIND & 1) != 0;
  bool internal = (CXXV_BLOB_KIND & 2) != 0;
#else
  bool is_string = nondet_bool();
  bool internal = nondet_bool();
#endif
  if (internal) CXXV_ASSUME(length < 0x4000);
  HeapObject* result;
  if (is_string) {
    if (internal) {
      result = raw_object(String::INTERNAL_HEADER_SIZE + length + 1);
      set_header(result, Program::string_class_id_INDEX, STRING_TAG);
      String* string = static_cast<String*>(result);
      string->_set_length(length);
      reinterpret_cast<uint8*>(string->_raw_at(String::INTERNAL_HEADER_SIZE))[length] = 0;
    } else {
      result = raw_object(String::EXTERNAL_OBJECT_SIZE);
      set_header(result, Program::string_class_id_INDEX, STRING_TAG);
      String* string = static_cast<String*>(result);
      string->_set_external_length(length);
      uint8* content = static_cast<uint8*>(malloc(length + 1));
      CXXV_ASSUME(content != null);
      content[length] = 0;
      string->_set_external_address(content);
    }
  } else {
    if (internal) {
      result = raw_object(ByteArray::HEADER_SIZE + length);
      set_header(result, Program::byte_array_class_id_INDEX, BYTE_ARRAY_TAG);
      static_cast<ByteArray*>(result)->_set_length(length);
    } else {
      result = raw_object(ByteArray::EXTERNAL_SIZE);
      set_header(result, Program::byte_array_class_id_INDEX, BYTE_ARRAY_TAG);
      ByteArray* bytes = static_cast<ByteArray*>(result);
      bytes->_set_external_length(length);
      uint8* content = static_cast<uint8*>(malloc(length == 0 ? 1 : length));
      CXXV_ASSUME(content != null);
      bytes->_set_external_address(content);
      bytes->_set_external_tag(RawByteTag);
    }
  }
  return result;
}

// The error a primitive returns with FAIL(name) (src/primitive.h).
static inline Object* failure(int index) {
  return reinterpret_cast<Object*>((index << Error::ERROR_SHIFT) | Error::ERROR_TAG);
}

static inline Object* nondet_leaf(World* world) {
  switch (nondet_int()) {
    case 0: return world->program->null_object();
    case 1: return world->program->true_object();
    case 2: return nondet_string();
    case 3: return nondet_byte_array();
    default: return nondet_smi();
  }
}

static inline Array* nondet_array(World* world, int depth) {
  word length = nondet_int();
  CXXV_ASSUME(0 <= length && length <= CXXV_ARRAY);
  HeapObject* result = raw_object(Array::HEADER_SIZE + length * WORD_SIZE);
  set_header(result, Program::array_class_id_INDEX, ARRAY_TAG);
  Array* array = static_cast<Array*>(result);
  array->_set_length(length);
  for (word i = 0; i < CXXV_ARRAY; i++) {  // Constant bound: unrolled exactly.
    if (i < length) array->at_put_no_write_barrier(i, nondet_object(world, depth - 1));
  }
  return array;
}

// An instance of a builtin collection class or of a user class, with at
// least the fields G3 guarantees; every field is a nondeterministic value.
static inline Instance* nondet_instance(World* world, int depth) {
  int class_id = nondet_int();
  CXXV_ASSUME(class_id == Program::list_class_id_INDEX ||
              class_id == Program::list_slice_class_id_INDEX ||
              class_id == Program::map_class_id_INDEX ||
              class_id == Program::byte_array_cow_class_id_INDEX ||
              class_id == Program::byte_array_slice_class_id_INDEX ||
              class_id == Program::string_slice_class_id_INDEX ||
              class_id == Program::string_byte_slice_class_id_INDEX ||
              class_id == Program::tombstone_class_id_INDEX ||
              class_id == USER_CLASS_ID);
  int fields = nondet_int();
  CXXV_ASSUME(min_fields(class_id) <= fields && fields <= min_fields(class_id) + CXXV_FIELDS);
  HeapObject* result = raw_object(Instance::HEADER_SIZE + fields * WORD_SIZE);
  set_header(result, class_id, INSTANCE_TAG);
  Instance* instance = static_cast<Instance*>(result);
  for (int i = 0; i < 8 + CXXV_FIELDS; i++) {  // Constant bound (min_fields <= 8).
    if (i < fields) instance->at_put_no_write_barrier(i, nondet_object(world, depth - 1));
  }
  return instance;
}

// Pilot (b): the collections whose fields the encoders read. A List_,
// ListSlice_ or Map_ instance with the guaranteed fields (G3) and nothing
// else; sizes, bounds and other smi fields are arbitrary smis; the backing
// is an array of at most CXXV_ARRAY elements, a List_ over such an array
// (with an arbitrary size), a smi or null. Elements are smis or null. This
// bounds the shapes explored (other backings fail the encoders' type
// checks before any field is read), not the VM guarantees.
static inline Object* nondet_small_leaf(World* world) {
#ifdef CXXV_NULL_ELEMENTS
  // Costly: a heap object as element makes the tool explore every case of
  // the encoders (strings, slices, nested collections) per element.
  if (nondet_bool()) return world->program->null_object();
#endif
#ifdef CXXV_SYMBOLIC_ELEMENTS
  return nondet_smi();
#else
  // A constant smi: the tool then decides is_smi(element) while unrolling,
  // instead of following every case of the encoders' recursion for each
  // element down to their nesting limit (which exhausts memory). Element
  // values are irrelevant to the bounds the encoders check.
  return Smi::from(7);
#endif
}

static inline Array* nondet_small_array(World* world) {
  word length = nondet_int();
  CXXV_ASSUME(0 <= length && length <= CXXV_ARRAY);
  HeapObject* result = raw_object(Array::HEADER_SIZE + length * WORD_SIZE);
  set_header(result, Program::array_class_id_INDEX, ARRAY_TAG);
  Array* array = static_cast<Array*>(result);
  array->_set_length(length);
  for (word i = 0; i < CXXV_ARRAY; i++) {  // Constant bound: unrolled exactly.
    if (i < length) array->at_put_no_write_barrier(i, nondet_small_leaf(world));
  }
  return array;
}

static inline Instance* new_instance(int class_id, int fields) {
  HeapObject* result = raw_object(Instance::HEADER_SIZE + fields * WORD_SIZE);
  set_header(result, class_id, INSTANCE_TAG);
  return static_cast<Instance*>(result);
}

static inline Instance* nondet_list_over_array(World* world) {
  Instance* list = new_instance(Program::list_class_id_INDEX, Instance::LIST_SIZE_INDEX + 1);
  list->at_put_no_write_barrier(Instance::LIST_ARRAY_INDEX, nondet_small_array(world));
  list->at_put_no_write_barrier(Instance::LIST_SIZE_INDEX, nondet_smi());
  return list;
}

static inline Object* nondet_backing(World* world) {
#ifdef CXXV_BACKING
  switch (CXXV_BACKING) {
#else
  switch (nondet_int()) {
#endif
    case 0: return nondet_small_array(world);
    case 1: return nondet_list_over_array(world);
    default: return nondet_small_leaf(world);
  }
}

static inline Instance* nondet_collection(World* world) {
  // CXXV_COLLECTION fixes the kind (0 List_, 1 ListSlice_, 2 Map_) and
  // CXXV_BACKING the backing (0 array, 1 List_ over an array, 2 smi) per
  // run: concrete class ids let the tool prune the encoders' other cases
  // (a merged, symbolic class id makes it follow the blob and slice cases
  // into memcpy loops of symbolic length, which exhausts memory).
#ifdef CXXV_COLLECTION
  switch (CXXV_COLLECTION) {
#else
  switch (nondet_int()) {
#endif
    case 0: {
      Instance* list = new_instance(Program::list_class_id_INDEX, Instance::LIST_SIZE_INDEX + 1);
      list->at_put_no_write_barrier(Instance::LIST_ARRAY_INDEX, nondet_backing(world));
      list->at_put_no_write_barrier(Instance::LIST_SIZE_INDEX, nondet_smi());
      return list;
    }
    case 1: {
      Instance* slice = new_instance(Program::list_slice_class_id_INDEX, Instance::LIST_SLICE_TO_INDEX + 1);
      slice->at_put_no_write_barrier(Instance::LIST_SLICE_LIST_INDEX, nondet_backing(world));
      slice->at_put_no_write_barrier(Instance::LIST_SLICE_FROM_INDEX, nondet_smi());
      slice->at_put_no_write_barrier(Instance::LIST_SLICE_TO_INDEX, nondet_smi());
      return slice;
    }
    default: {
      Instance* map = new_instance(Program::map_class_id_INDEX, Instance::MAP_BACKING_INDEX + 1);
      map->at_put_no_write_barrier(Instance::MAP_SIZE_INDEX, nondet_smi());
      map->at_put_no_write_barrier(Instance::MAP_SPACES_LEFT_INDEX, nondet_smi());
      map->at_put_no_write_barrier(Instance::MAP_INDEX_INDEX, nondet_small_leaf(world));
      map->at_put_no_write_barrier(Instance::MAP_BACKING_INDEX, nondet_backing(world));
      return map;
    }
  }
}

static inline Object* nondet_object(World* world, int depth) {
  if (depth <= 0) return nondet_leaf(world);
  switch (nondet_int()) {
    case 0: return nondet_array(world, depth);
    case 1: return nondet_instance(world, depth);
    default: return nondet_leaf(world);
  }
}

}  // namespace cxxv

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

#include "entry_points.h"
#include "top.h"
#include "objects.h"
#include "program_memory.h"
#include "bytecodes.h"
#include "snapshot.h"
#include "flash_allocation.h"

namespace toit {

// List of all roots in program_heap.
#define PROGRAM_ROOTS(ROOT)                  \
  ROOT(HeapObject, null_object)              \
  ROOT(HeapObject, true_object)              \
  ROOT(HeapObject, false_object)             \
  ROOT(Array,      empty_array)              \
  ROOT(Array,      snapshot_arguments)       \
  ROOT(Instance,   out_of_memory_error)      \
  ROOT(String,     app_sdk_version)          \
  ROOT(String,     app_sdk_info)             \
  \
  ROOT(String,     allocation_failed)        \
  ROOT(String,     allocation_size_exceeded) \
  ROOT(String,     already_closed)           \
  ROOT(String,     already_exists)           \
  ROOT(String,     division_by_zero)         \
  ROOT(String,     error)                    \
  ROOT(String,     file_not_found)           \
  ROOT(String,     hardware_error)           \
  ROOT(String,     illegal_utf_8)            \
  ROOT(String,     invalid_argument)         \
  ROOT(String,     malloc_failed)            \
  ROOT(String,     cross_process_gc)         \
  ROOT(String,     negative_argument)        \
  ROOT(String,     out_of_bounds)            \
  ROOT(String,     out_of_range)             \
  ROOT(String,     already_in_use)           \
  ROOT(String,     overflow)                 \
  ROOT(String,     privileged_primitive)     \
  ROOT(String,     permission_denied)        \
  ROOT(String,     quota_exceeded)           \
  ROOT(String,     read_failed)              \
  ROOT(String,     stack_overflow)           \
  ROOT(String,     unimplemented)            \
  ROOT(String,     wrong_object_type)        \


#define BUILTIN_CLASS_IDS(ID)    \
  ID(string_class_id)            \
  ID(array_class_id)             \
  ID(byte_array_class_id)        \
  ID(byte_array_cow_class_id)    \
  ID(byte_array_slice_class_id)  \
  ID(string_slice_class_id)      \
  ID(list_class_id)              \
  ID(tombstone_class_id)         \
  ID(stack_class_id)             \
  ID(null_class_id)              \
  ID(true_class_id)              \
  ID(false_class_id)             \
  ID(object_class_id)            \
  ID(double_class_id)            \
  ID(large_integer_class_id)     \
  ID(smi_class_id)               \
  ID(task_class_id)              \
  ID(large_array_class_id)       \
  ID(lazy_initializer_class_id)  \
  ID(exception_class_id)         \

static const int FREE_LIST_REGION_CLASS_ID = -1;
static const int SINGLE_FREE_WORD_CLASS_ID = -2;
static const int PROMOTED_TRACK_CLASS_ID = -3;

// The reflective structure of a program.
class Program : public FlashAllocation {
 public:
  Program(void* program_heap_address, uword program_heap_size);
  ~Program();

  #define DECLARE_ROOT(type, name) name##_INDEX,
  enum {
    PROGRAM_ROOTS(DECLARE_ROOT)
    ROOT_COUNT
  };
  #undef DECLARE_ROOT

  #define DECLARE_BUILTIN_CLASS_IDS(name) name##_INDEX,
  enum {
    BUILTIN_CLASS_IDS(DECLARE_BUILTIN_CLASS_IDS)
    BUILTIN_CLASS_IDS_COUNT
  };
  #undef DECLARE_BUILTIN_CLASS_IDS

  #define DECLARE_ENTRY_POINT(name, lib_name, arity) name##_INDEX,
  enum {
    ENTRY_POINTS(DECLARE_ENTRY_POINT)
    ENTRY_POINTS_COUNT
  };
  #undef DECLARE_ENTRY_POINT

  Object* root(int index) const { ASSERT(index >= 0 && index < ROOT_COUNT); return _roots[index]; }

  #define DECLARE_ROOT_ACCESSOR(type, name) type* name() { return static_cast<type*>(_roots[name##_INDEX]); }
  PROGRAM_ROOTS(DECLARE_ROOT_ACCESSOR)
  #undef DECLARE_ROOT_ACCESSOR

  #define DECLARE_ENTRY_POINT_ACCESSOR(name, lib_name, arity) Method name() { \
    int dispatch_index = _entry_point_indexes[name##_INDEX]; \
    return Method(&bytecodes[dispatch_table[dispatch_index]]); }
  ENTRY_POINTS(DECLARE_ENTRY_POINT_ACCESSOR)
  #undef DECLARE_ENTRY_POINT_ACCESSOR

  Smi* class_id(int index) const { ASSERT(index >= 0 && index < BUILTIN_CLASS_IDS_COUNT); return _builtin_class_ids[index]; }

  #define DECLARE_BUILTIN_CLASS_ID_ACCESSOR(name) Smi* name() { return _builtin_class_ids[name##_INDEX]; }
    BUILTIN_CLASS_IDS(DECLARE_BUILTIN_CLASS_ID_ACCESSOR)
  #undef DECLARE_BUILTIN_CLASS_ID_ACCESSOR


  // Implementation is located in interpreter_run.cc
  inline Method find_method(Object* receiver, int offset);

  static const int CLASS_TAG_MASK = (1 << HeapObject::CLASS_TAG_BIT_SIZE) - 1;
  static const int INSTANCE_SIZE_BIT_SIZE = 16 - HeapObject::CLASS_TAG_BIT_SIZE;
  static const int INSTANCE_SIZE_MASK = (1 << INSTANCE_SIZE_BIT_SIZE) - 1;

  inline TypeTag class_tag_for(Smi* class_id) {
    return class_tag_from_class_bits(class_bits[class_id->value()]);
  }

  static inline TypeTag class_tag_from_class_bits(int class_bits) {
    return static_cast<TypeTag>(class_bits & CLASS_TAG_MASK);
  }

  inline int instance_size_for(Smi* class_id) {
    word value = class_id->value();
    if (value < 0) {
      if (value == SINGLE_FREE_WORD_CLASS_ID) return sizeof(word);
      return 0;  // Variable sized object - free-list region or promoted track.
    }
    return instance_size_from_class_bits(class_bits[value]);
  }

  static inline int instance_size_from_class_bits(int class_bits) {
    return ((class_bits >> HeapObject::CLASS_TAG_BIT_SIZE) & INSTANCE_SIZE_MASK) * WORD_SIZE;
  }

  int instance_size_for(HeapObject* object) {
    return instance_size_for(object->class_id());
  }

#ifndef TOIT_FREERTOS
  // Snapshot operations.
  void write(SnapshotWriter* st);
  void read(SnapshotReader* st);
#endif

  // Size of all objects stored in this program.
  int object_size() const { return _heap.object_size(); }

  // Return the program heap.
  ProgramRawHeap* heap() { return &_heap; }
  // The address of where the program heap starts.
  // The returned address points to the the first block's header.
  void* heap_address() { return _heap._blocks.first(); }

  ProgramUsage usage();

  int number_of_unused_dispatch_table_entries();

  void do_roots(RootCallback* callback);

  void take_blocks(ProgramBlockList* blocks) {
    _heap.take_blocks(blocks);
  }

  bool is_valid_program() const;

  void validate();

  String* source_mapping() const { return _source_mapping; }

  int invoke_bytecode_offset(Opcode opcode) const {
    ASSERT(opcode >= INVOKE_EQ && opcode <= INVOKE_AT_PUT);
    return _invoke_bytecode_offsets[opcode - INVOKE_EQ];
  }

  template <typename T> class Table {
   public:
    Table() : _array(null), _length(-1) {}
    ~Table() {
      if (_array != null) free(_array);
    }

    void create(int length) {
      T* array = unvoid_cast<T*>(malloc(sizeof(T) * length));
      ASSERT(array != null);
      for (int i = length - 1; i >= 0; i--) array[i] = null;
      _array = array;
      _length = length;
    }

    T at(int index) {
      ASSERT(index >= 0 && index < _length);
      return _array[index];
    }

    void at_put(int index, T value) {
      ASSERT(index >= 0 && index < _length);
      _array[index] = value;
    }

    T* array() const { return _array; }
    int length() const { return _length; }

#ifndef TOIT_FREERTOS
    void read(SnapshotReader* st) {
      _array = reinterpret_cast<T*>(st->read_external_object_table(&_length));
    }

    void write(SnapshotWriter* st) {
      st->write_external_object_table(raw_array(), length());
    }
#endif

    void do_roots(RootCallback* callback) {
      callback->do_roots(raw_array(), length());
    }

    void do_pointers(PointerCallback* callback) {
      callback->object_table(raw_array(), length());
      callback->c_address(reinterpret_cast<void**>(&_array));
    }

    Object** copy() {
      Object** copy = unvoid_cast<Object**>(malloc(sizeof(Object*) * length()));
      ASSERT(copy != null);
      memcpy(copy, raw_array(), sizeof(Object*) * length());
      return copy;
    }

   private:
    T* _array;
    int _length;

    Object** raw_array() { return reinterpret_cast<Object**>(_array); }

    friend class Program;
  };

  int absolute_bci_from_bcp(uint8* bcp) const;
  uint8* bcp_from_absolute_bci(int absolute_bci) { return &bytecodes.data()[absolute_bci]; }

  // Pointers into the bytecodes are ignored by the GC. This means that we can
  //   use one of them as frame_marker.
  // We point to the beginning of the bytecodes. This is a valid Method address,
  //   but not a valid bcp, as it points to the header of the first method, and
  //   not its bytecodes.
  inline Object* frame_marker() const {
    uword bytecodes_address = reinterpret_cast<uword>(bytecodes.data());
    ASSERT(is_smi(reinterpret_cast<Object*>(bytecodes_address)));
    auto result = reinterpret_cast<Object*>(bytecodes_address + Object::HEAP_TAG);
    ASSERT(is_heap_object(result));
    return result;
  }

 public:
  Table<Object*> global_variables;
  Table<Object*> literals;
  List<int32> dispatch_table;
  List<uint16> class_check_ids;          // Pairs of start/end id.
  List<uint16> interface_check_offsets;  // Selector offsets.
  List<uint16> class_bits;               // Instance sizes and class tags.
  List<uint8> bytecodes;

 private:
  static const int INVOKE_BYTECODE_COUNT = INVOKE_AT_PUT - INVOKE_EQ + 1;
  int _invoke_bytecode_offsets[INVOKE_BYTECODE_COUNT];

  static uint16 compute_class_bits(TypeTag tag, int instance_byte_size) {
    ASSERT(0 <= instance_byte_size);
    ASSERT(Utils::is_aligned(instance_byte_size, WORD_SIZE));
    instance_byte_size = instance_byte_size / WORD_SIZE;
    if (instance_byte_size > INSTANCE_SIZE_MASK) FATAL("Invalid instance size");
    return (instance_byte_size << HeapObject::CLASS_TAG_BIT_SIZE) | tag;
  }

  void set_invoke_bytecode_offset(Opcode opcode, int offset) {
    ASSERT(opcode >= INVOKE_EQ && opcode <= INVOKE_AT_PUT);
    _invoke_bytecode_offsets[opcode - INVOKE_EQ] = offset;
  }

  uword tables_size() {
    return WORD_SIZE * (global_variables.length() + literals.length()) +
            sizeof(uint32) * dispatch_table.length() +
            sizeof(uint16) * (class_bits.length() + interface_check_offsets.length() + class_check_ids.length());
  }

  ProgramRawHeap _heap;

  Object* _roots[ROOT_COUNT];
  #define DECLARE_ROOT(type, name) void set_##name(type* v) { _roots[name##_INDEX] = v; }
  PROGRAM_ROOTS(DECLARE_ROOT)
  #undef DECLARE_ROOT

  Smi* _builtin_class_ids[BUILTIN_CLASS_IDS_COUNT];
  #define DECLARE_CLASS_ID_ROOT(name) void set_##name(Smi* v) { _builtin_class_ids[name##_INDEX] = v; }
  BUILTIN_CLASS_IDS(DECLARE_CLASS_ID_ROOT)
  #undef DECLARE_CLASS_ID_ROOT

  int _entry_point_indexes[ENTRY_POINTS_COUNT];
  void _set_entry_point_index(int entry_point_index, int dispatch_index) {
    ASSERT(0 <= entry_point_index && entry_point_index < ENTRY_POINTS_COUNT);
    ASSERT(entry_point_index >= 0);
    _entry_point_indexes[entry_point_index] = dispatch_index;
  }

  String* _source_mapping;
  void set_source_mapping(String* mapping) { _source_mapping = mapping; }

  void set_dispatch_table(List<int32> table) { dispatch_table = table; }
  void set_class_bits_table(List<uint16> table) { class_bits = table; }
  void set_class_check_ids(List<uint16> ids) { class_check_ids = ids; }
  void set_interface_check_offsets(List<uint16> offsets) { interface_check_offsets = offsets; }
  void set_bytecodes(List<uint8> codes) { bytecodes = codes; }

  // Should only be called from ProgramImage.
  void do_pointers(PointerCallback* callback);

  uword _program_heap_address;
  uword _program_heap_size;

  friend class Process;
  friend class ProgramHeap;
  friend class ImageAllocator;
  friend class compiler::ProgramBuilder;
  friend class ProgramImage;
};

#undef PROGRAM_ROOTS
#undef BUILTIN_CLASS_IDS
#undef BUILTINS

} // namespace toit

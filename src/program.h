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
  ROOT(Instance,   out_of_memory_error)      \
  ROOT(String,     app_sdk_version)          \
  ROOT(String,     app_sdk_info)             \

#define ERROR_STRINGS(ERROR_STRING)                                 \
  ERROR_STRING(allocation_failed, ALLOCATION_FAILED)                \
  ERROR_STRING(allocation_size_exceeded, ALLOCATION_SIZE_EXCEEDED)  \
  ERROR_STRING(already_closed, ALREADY_CLOSED)                      \
  ERROR_STRING(already_exists, ALREADY_EXISTS)                      \
  ERROR_STRING(division_by_zero, DIVISION_BY_ZERO)                  \
  ERROR_STRING(error, ERROR)                                        \
  ERROR_STRING(file_not_found, FILE_NOT_FOUND)                      \
  ERROR_STRING(hardware_error, HARDWARE_ERROR)                      \
  ERROR_STRING(illegal_utf_8, ILLEGAL_UTF_8)                        \
  ERROR_STRING(invalid_argument, INVALID_ARGUMENT)                  \
  ERROR_STRING(malloc_failed, MALLOC_FAILED)                        \
  ERROR_STRING(cross_process_gc, CROSS_PROCESS_GC)                  \
  ERROR_STRING(negative_argument, NEGATIVE_ARGUMENT)                \
  ERROR_STRING(out_of_bounds, OUT_OF_BOUNDS)                        \
  ERROR_STRING(out_of_range, OUT_OF_RANGE)                          \
  ERROR_STRING(already_in_use, ALREADY_IN_USE)                      \
  ERROR_STRING(overflow, OVERFLOW)                                  \
  ERROR_STRING(privileged_primitive, PRIVILEGED_PRIMITIVE)          \
  ERROR_STRING(permission_denied, PERMISSION_DENIED)                \
  ERROR_STRING(quota_exceeded, QUOTA_EXCEEDED)                      \
  ERROR_STRING(read_failed, READ_FAILED)                            \
  ERROR_STRING(stack_overflow, STACK_OVERFLOW)                      \
  ERROR_STRING(unimplemented, UNIMPLEMENTED)                        \
  ERROR_STRING(wrong_object_type, WRONG_OBJECT_TYPE)                \
  ERROR_STRING(wrong_bytes_type, WRONG_BYTES_TYPE)                  \
  ERROR_STRING(invalid_signature, INVALID_SIGNATURE)                \
  ERROR_STRING(invalid_state, INVALID_STATE)                        \
  ERROR_STRING(unsupported, UNSUPPORTED)                            \

#define BUILTIN_CLASS_IDS(ID)     \
  ID(string_class_id)             \
  ID(array_class_id)              \
  ID(byte_array_class_id)         \
  ID(byte_array_cow_class_id)     \
  ID(byte_array_slice_class_id)   \
  ID(string_slice_class_id)       \
  ID(string_byte_slice_class_id)  \
  ID(list_class_id)               \
  ID(list_slice_class_id)         \
  ID(map_class_id)                \
  ID(tombstone_class_id)          \
  ID(stack_class_id)              \
  ID(null_class_id)               \
  ID(true_class_id)               \
  ID(false_class_id)              \
  ID(object_class_id)             \
  ID(double_class_id)             \
  ID(large_integer_class_id)      \
  ID(smi_class_id)                \
  ID(task_class_id)               \
  ID(large_array_class_id)        \
  ID(lazy_initializer_class_id)   \
  ID(exception_class_id)          \

static const int FREE_LIST_REGION_CLASS_ID = -1;
static const int SINGLE_FREE_WORD_CLASS_ID = -2;
static const int PROMOTED_TRACK_CLASS_ID = -3;

// The reflective structure of a program.
class Program : public FlashAllocation {
 public:
  Program(const uint8* id, int size);

  #define DECLARE_ROOT(type, name) name##_INDEX,
  #define DECLARE_ERROR(name, upper_name) upper_name##_INDEX,
  enum {
    PROGRAM_ROOTS(DECLARE_ROOT)
    ERROR_STRINGS(DECLARE_ERROR)
    ROOT_COUNT
  };
  #undef DECLARE_ROOT
  #undef DECLARE_ERROR

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

  Object* root(int index) const { ASSERT(index >= 0 && index < ROOT_COUNT); return roots_[index]; }

  #define DECLARE_ROOT_ACCESSOR(type, name) type* name() const { return static_cast<type*>(roots_[name##_INDEX]); }
  #define DECLARE_ERROR_ACCESSOR(name, upper_name) String* name() const { return static_cast<String*>(roots_[upper_name##_INDEX]); }
  PROGRAM_ROOTS(DECLARE_ROOT_ACCESSOR)
  ERROR_STRINGS(DECLARE_ERROR_ACCESSOR)
  #undef DECLARE_ROOT_ACCESSOR
  #undef DECLARE_ERROR_ACCESSOR

  #define DECLARE_ENTRY_POINT_ACCESSOR(name, lib_name, arity) Method name() { \
    int dispatch_index = entry_point_indexes_[name##_INDEX]; \
    return Method(&bytecodes[dispatch_table[dispatch_index]]); }
  ENTRY_POINTS(DECLARE_ENTRY_POINT_ACCESSOR)
  #undef DECLARE_ENTRY_POINT_ACCESSOR

  Smi* class_id(int index) const { ASSERT(index >= 0 && index < BUILTIN_CLASS_IDS_COUNT); return _builtin_class_ids[index]; }

  #define DECLARE_BUILTIN_CLASS_ID_ACCESSOR(name) Smi* name() const { return _builtin_class_ids[name##_INDEX]; }
    BUILTIN_CLASS_IDS(DECLARE_BUILTIN_CLASS_ID_ACCESSOR)
  #undef DECLARE_BUILTIN_CLASS_ID_ACCESSOR

  Object* boolean(bool value) const {
    return value ? true_object() : false_object();
  }

  // Implementation is located in interpreter_run.cc
  inline Method find_method(Object* receiver, word offset);

  static const int CLASS_TAG_MASK = (1 << HeapObject::CLASS_TAG_BIT_SIZE) - 1;
  static const int INSTANCE_SIZE_BIT_SIZE = 16 - HeapObject::CLASS_ID_OFFSET;
  static const int INSTANCE_SIZE_MASK = (1 << INSTANCE_SIZE_BIT_SIZE) - 1;

  inline TypeTag class_tag_for(Smi* class_id) {
    return class_tag_from_class_bits(class_bits[Smi::value(class_id)]);
  }

  static inline TypeTag class_tag_from_class_bits(int class_bits) {
    return static_cast<TypeTag>(class_bits & CLASS_TAG_MASK);
  }

  inline int instance_fields_for(Smi* class_id) {
    return Instance::fields_from_size(allocation_instance_size_for(class_id));
  }

  inline int allocation_instance_size_for(Smi* class_id) {
    word value = Smi::value(class_id);
    ASSERT(value >= 0);
    return instance_size_from_class_bits(class_bits[value]);
  }

  static inline int instance_size_from_class_bits(int class_bits) {
    return ((class_bits >> HeapObject::CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) * WORD_SIZE;
  }

  int instance_size_for(const HeapObject* object) {
    word value = Smi::value(object->class_id());
    if (value < 0) {
      if (value == SINGLE_FREE_WORD_CLASS_ID) return sizeof(word);
      return 0;  // Variable sized object - free-list region or promoted track.
    }
    return instance_size_from_class_bits(class_bits[value]);
  }

#ifndef TOIT_FREERTOS
  // Snapshot operations.
  void write(SnapshotWriter* st);
  void read(SnapshotReader* st);
#endif

  // Size of all objects stored in this program.
  int object_size() const { return heap_.object_size(); }

  // Get the snapshot uuid for the program. This is useful for associating
  // encoded stack traces with the snapshot containing the symbolic debug
  // information.
  const uint8* snapshot_uuid() const { return snapshot_uuid_; }

  // Return the program heap.
  ProgramRawHeap* heap() { return &heap_; }
  // The address of where the program heap starts.
  // The returned address points to the the first block's header.
  void* heap_address() { return heap_.blocks_.first(); }

  ProgramUsage usage();

  int number_of_unused_dispatch_table_entries();

  void do_roots(RootCallback* callback);

  void take_blocks(ProgramBlockList* blocks) {
    heap_.take_blocks(blocks);
  }

  int invoke_bytecode_offset(Opcode opcode) const {
    ASSERT(opcode >= INVOKE_EQ && opcode <= INVOKE_SIZE);
    return invoke_bytecode_offsets_[opcode - INVOKE_EQ];
  }

  template <typename T> class Table {
   public:
    Table() : array_(null), length_(-1) {}
    ~Table() {
      if (array_ != null) free(array_);
    }

    void create(int length) {
      T* array = unvoid_cast<T*>(malloc(sizeof(T) * length));
      ASSERT(array != null);
      for (int i = length - 1; i >= 0; i--) array[i] = null;
      array_ = array;
      length_ = length;
    }

    T at(int index) {
      ASSERT(index >= 0 && index < length_);
      return array_[index];
    }

    void at_put(int index, T value) {
      ASSERT(index >= 0 && index < length_);
      array_[index] = value;
    }

    T* array() const { return array_; }
    int length() const { return length_; }

#ifndef TOIT_FREERTOS
    void read(SnapshotReader* st) {
      array_ = reinterpret_cast<T*>(st->read_external_object_table(&length_));
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
      callback->c_address(reinterpret_cast<void**>(&array_));
    }

    Object** copy() {
      Object** copy = unvoid_cast<Object**>(malloc(sizeof(Object*) * length()));
      if (copy == null) return copy;
      memcpy(copy, raw_array(), sizeof(Object*) * length());
      return copy;
    }

   private:
    T* array_;
    int length_;

    Object** raw_array() { return reinterpret_cast<Object**>(array_); }

    friend class Program;
  };

  bool is_valid_bcp(uint8* bcp) const {
    return bytecodes.data() <= bcp && bcp < bytecodes.data() + bytecodes.length();
  }

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

  int global_max_stack_height() const { return global_max_stack_height_; }

 public:
  Table<Object*> global_variables;
  Table<Object*> literals;
  List<int32> dispatch_table;
  List<uint16> class_check_ids;          // Pairs of start/end id.
  List<uint16> interface_check_offsets;  // Selector offsets.
  List<uint16> class_bits;               // Instance sizes and class tags.
  List<uint8> bytecodes;

 private:
  // ATTENTION: The snapshot uuid is decoded by tools/firmware.toit. You
  // need to update that if the offset of the field changes.
  uint8 snapshot_uuid_[UUID_SIZE];
  word global_max_stack_height_;         // Maximum stack height for all methods.

  static const int INVOKE_BYTECODE_COUNT = INVOKE_SIZE - INVOKE_EQ + 1;
  int invoke_bytecode_offsets_[INVOKE_BYTECODE_COUNT];

  static uint16 compute_class_bits(TypeTag tag, int instance_byte_size) {
    ASSERT(0 <= instance_byte_size);
    ASSERT(Utils::is_aligned(instance_byte_size, WORD_SIZE));
    instance_byte_size = instance_byte_size / WORD_SIZE;
    if (instance_byte_size > INSTANCE_SIZE_MASK) FATAL("Invalid instance size");
    return (instance_byte_size << HeapObject::CLASS_ID_OFFSET) | tag;
  }

  void set_invoke_bytecode_offset(Opcode opcode, word offset) {
    ASSERT(opcode >= INVOKE_EQ && opcode <= INVOKE_SIZE);
    invoke_bytecode_offsets_[opcode - INVOKE_EQ] = offset;
  }

  uword tables_size() {
    return WORD_SIZE * (global_variables.length() + literals.length()) +
            sizeof(uint32) * dispatch_table.length() +
            sizeof(uint16) * (class_bits.length() + interface_check_offsets.length() + class_check_ids.length());
  }

  ProgramRawHeap heap_;

  Object* roots_[ROOT_COUNT];
  #define DECLARE_ROOT(type, name) void set_##name(type* v) { roots_[name##_INDEX] = v; }
  #define DECLARE_ERROR(name, upper_name) void set_##name(String* v) { roots_[upper_name##_INDEX] = v; }
  PROGRAM_ROOTS(DECLARE_ROOT)
  ERROR_STRINGS(DECLARE_ERROR)
  #undef DECLARE_ROOT
  #undef DECLARE_ERROR

  Smi* _builtin_class_ids[BUILTIN_CLASS_IDS_COUNT];
  #define DECLARE_CLASS_ID_ROOT(name) void set_##name(Smi* v) { _builtin_class_ids[name##_INDEX] = v; }
  BUILTIN_CLASS_IDS(DECLARE_CLASS_ID_ROOT)
  #undef DECLARE_CLASS_ID_ROOT

  int entry_point_indexes_[ENTRY_POINTS_COUNT];
  void _set_entry_point_index(int entry_point_index, int dispatch_index) {
    ASSERT(0 <= entry_point_index && entry_point_index < ENTRY_POINTS_COUNT);
    ASSERT(entry_point_index >= 0);
    entry_point_indexes_[entry_point_index] = dispatch_index;
  }

  void set_dispatch_table(List<int32> table) { dispatch_table = table; }
  void set_class_bits_table(List<uint16> table) { class_bits = table; }
  void set_class_check_ids(List<uint16> ids) { class_check_ids = ids; }
  void set_interface_check_offsets(List<uint16> offsets) { interface_check_offsets = offsets; }
  void set_bytecodes(List<uint8> codes) { bytecodes = codes; }
  void set_global_max_stack_height(int height) { global_max_stack_height_ = height; }

  // Should only be called from ProgramImage.
  void do_pointers(PointerCallback* callback);

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

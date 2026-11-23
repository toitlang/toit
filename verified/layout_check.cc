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

// Layout contract check for the verified interpreter core.
//
// Every constant the Rust core assumes (verified/core/src/layout.rs, the
// FFI structs of verified/core/src/ffi.rs and the opcode numbers of
// verified/core/src/machine.rs) is exported by name. This program compares
// each one against the value derived from the C++ headers. Offsets that are
// private in C++ are checked behaviorally: a fake object is built in a
// buffer with distinct marker words and the C++ accessor tells which word
// it reads. The check fails (non-zero exit, which fails the build) on any
// mismatch, on any Rust constant it does not know, and on any expected
// constant the Rust side does not export.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TOIT_VERIFIED_CORE 1
#include "top.h"
#include "bytecodes.h"
#include "objects.h"
#include "objects_inline.h"
#include "program.h"
#include "interpreter.h"
#include "interpreter_v2.h"
#include "primitive.h"
#include "verifier_v2.h"
#include "tags.h"
#include "third_party/dartino/gc_metadata.h"
#include "third_party/dartino/object_memory.h"

using namespace toit;

namespace {

int failures = 0;

void fail(const char* what, uword rust, uword cxx) {
  printf("FAIL: %s: Rust %lu, C++ %lu\n", what,
         static_cast<unsigned long>(rust), static_cast<unsigned long>(cxx));
  failures++;
}

struct Expected {
  const char* name;
  uword value;
  bool seen;
};

uword smi_bits(word value) {
  return reinterpret_cast<uword>(Smi::from(value));
}

// Stores a half word (32 bits on 64-bit targets, 16 on 32-bit ones).
void put_half(uint8* at, uword value) {
  if (HALF_WORD_SIZE == 4) {
    uint32 v = static_cast<uint32>(value);
    memcpy(at, &v, 4);
  } else {
    uint16 v = static_cast<uint16>(value);
    memcpy(at, &v, 2);
  }
}

// A fake heap object: 64 words, word k holds `marker(k)`.
struct Fake {
  alignas(16) uword words[64];
  Fake() { for (int i = 0; i < 64; i++) words[i] = marker(i); }
  static uword marker(int k) { return 0x1000 + 2 * k; }  // Smis, distinct.
  HeapObject* object() { return HeapObject::from_address(reinterpret_cast<uword>(words)); }
  // The word index a pointer into the fake points at.
  int word_of(const void* p) {
    return static_cast<int>((reinterpret_cast<uword>(p) - reinterpret_cast<uword>(words)) / WORD_SIZE);
  }
  int byte_of(const void* p) {
    return static_cast<int>(reinterpret_cast<uword>(p) - reinterpret_cast<uword>(words));
  }
};

int marker_index(uword value) {
  for (int k = 0; k < 64; k++) if (Fake::marker(k) == value) return k;
  return -1;
}

}  // namespace

// The core references the C++ helpers of src/interpreter_v2.cc; this
// program never runs the core.
extern "C" {
uword toit_v2_current_stack(void*) { abort(); }
uword toit_v2_allocate_instance(void*, uword) { abort(); }
uword toit_v2_allocate_double(void*, uint64) { abort(); }
uword toit_v2_allocate_exception(void*, uword, uword, const uword*, uword) { abort(); }
uword toit_v2_allocate_array(void*, uword, uword) { abort(); }
uword toit_v2_grow_stack(void*, uword) { abort(); }
uword toit_v2_try_allocate_large_integer(void*, int64) { abort(); }
uword toit_v2_try_allocate_double(void*, uint64) { abort(); }
uword toit_v2_try_allocate_array(void*, uword, void*) { abort(); }
uword toit_v2_try_allocate_string(void*, uword) { abort(); }
uword toit_v2_try_allocate_byte_array(void*, uword) { abort(); }
uword toit_v2_primitive(void*, uword, uword, uword, uword, uword*) { abort(); }
void toit_v2_report(void*, uword, uword, uword) { abort(); }
uword toit_v2_tracing(void*) { abort(); }
}

// Not linked into this program; stands for the computed hash of a string
// without a cached one.
static const uint16 ASSIGNED_HASH_MARKER = 0x4321;
uint16 toit::String::_assign_hash_code() { return ASSIGNED_HASH_MARKER; }

int main() {
  uword max_instruction_length = 0;
  for (int op = 0; op < V2_OPCODE_COUNT; op++) {
    if (V2_OPCODE_LENGTHS[op] > max_instruction_length) max_instruction_length = V2_OPCODE_LENGTHS[op];
  }
  // Behavioral offsets.
  int instance_fields_word;
  { Fake f; instance_fields_word = marker_index(reinterpret_cast<uword>(Instance::cast(f.object())->at(0))); }
  int array_length_word, array_elements_word;
  { Fake f;
    Array* a = static_cast<Array*>(f.object());
    array_length_word = marker_index(a->length());
    array_elements_word = marker_index(reinterpret_cast<uword>(a->at(0)));
  }
  int double_value_word, large_integer_value_word;
  { Fake f;
    double_value_word = marker_index(static_cast<uword>(static_cast<Double*>(f.object())->bits()));
    large_integer_value_word = marker_index(static_cast<uword>(static_cast<LargeInteger*>(f.object())->value()));
  }
  int byte_array_length_word = -1, byte_array_content_byte = -1;
  int byte_array_external_address_word = -1, byte_array_external_tag_word = -1;
  { Fake f;
    ByteArray* b = static_cast<ByteArray*>(f.object());
    // Find the raw length word: make every word a distinct small length.
    for (int k = 1; k < 8; k++) f.words[k] = 10 + k;
    ByteArray::Bytes bytes(b);
    byte_array_length_word = static_cast<int>(bytes.length()) - 10;
    byte_array_content_byte = f.byte_of(bytes.address());
    // External: the length word is negative.
    Fake g;
    ByteArray* e = static_cast<ByteArray*>(g.object());
    g.words[byte_array_length_word] = static_cast<uword>(-1 - 7);
    for (int k = 0; k < 64; k++) if (k != byte_array_length_word) g.words[k] = reinterpret_cast<uword>(&g.words[k]);
    g.words[0] = smi_bits(0);
    ByteArray::Bytes ext(e);
    byte_array_external_address_word = g.word_of(ext.address());
    if (ext.length() != 7) fail("ByteArray external length", 7, ext.length());
    Fake h;
    h.words[byte_array_length_word] = static_cast<uword>(-1 - 7);
    for (int k = 2; k < 8; k++) h.words[k] = RawByteTag + 100 * k;
    for (int k = 2; k < 8; k++) {
      if (static_cast<uword>(static_cast<ByteArray*>(h.object())->external_tag()) == h.words[k]) {
        byte_array_external_tag_word = k;
      }
    }
  }
  int string_content_byte = -1, string_external_length_word = -1, string_external_address_word = -1;
  int string_internal_length_byte = -1;
  { Fake f;
    memset(f.words, 0, sizeof(f.words));
    uint8* bytes = reinterpret_cast<uint8*>(f.words);
    // Find the internal length (a half word): try each half-word offset.
    for (int offset = WORD_SIZE; offset < 4 * WORD_SIZE; offset += HALF_WORD_SIZE) {
      memset(f.words, 0, sizeof(f.words));
      put_half(bytes + offset, 5);
      String::Bytes s(static_cast<String*>(f.object()));
      if (s.length() == 5) {
        string_internal_length_byte = offset;
        string_content_byte = f.byte_of(s.address());
        break;
      }
    }
    Fake g;
    for (int k = 0; k < 64; k++) g.words[k] = reinterpret_cast<uword>(&g.words[k]);
    memset(&g.words[1], 0, 8);
    put_half(reinterpret_cast<uint8*>(g.words) + string_internal_length_byte, 65535);
    for (int k = 2; k < 8; k++) g.words[k] = reinterpret_cast<uword>(&g.words[k]);
    String::Bytes s(static_cast<String*>(g.object()));
    string_external_address_word = g.word_of(s.address());
    string_external_length_word = g.word_of(reinterpret_cast<void*>(s.length()));
  }
  // The cached hash code: a half-word field holding 16 bits; find it by
  // planting a value. A string whose field holds NO_HASH_CODE computes its
  // hash instead (the stub below).
  int string_hash_code_byte = -1;
  uword string_no_hash_code = 0;
  for (int offset = WORD_SIZE; offset < 2 * WORD_SIZE && string_hash_code_byte < 0; offset += HALF_WORD_SIZE) {
    Fake f;
    memset(f.words, 0, sizeof(f.words));
    put_half(reinterpret_cast<uint8*>(f.words) + offset, 0x1234);
    if (static_cast<String*>(f.object())->hash_code() == 0x1234) string_hash_code_byte = offset;
  }
  if (string_hash_code_byte >= 0) {
    Fake f;
    memset(f.words, 0, sizeof(f.words));
    put_half(reinterpret_cast<uint8*>(f.words) + string_hash_code_byte, 0xFFFF);
    if (static_cast<String*>(f.object())->hash_code() == ASSIGNED_HASH_MARKER) string_no_hash_code = 0xFFFF;
  }
  int stack_length_word, stack_top_word, stack_record_top_word, stack_bci_word;
  bool stack_records_ok;
  { Fake f;
    Stack* s = static_cast<Stack*>(f.object());
    stack_length_word = marker_index(s->length());
    stack_top_word = marker_index(s->top());
    stack_record_top_word = marker_index(s->v2_record_top());
    stack_bci_word = marker_index(s->v2_bci_word());
    // The core writes `rtop | ftop << STACK_FRAME_TOP_SHIFT` and the bci
    // (Machine::save); C++ must read them back the same way.
    uword ftop = 13 * Stack::V2_FRAME_WORDS;
    uword rtop = ftop + 3 * Stack::V2_FIN_WORDS;
    f.words[stack_record_top_word] = rtop | (ftop << 16);
    f.words[stack_bci_word] = 0x7654321;
    stack_records_ok = s->v2_bci() == 0x7654321 && s->v2_fin_count() == 3 &&
        s->v2_frame_top() == static_cast<word>(ftop) && s->v2_record_top() == static_cast<word>(rtop);
    s->v2_set_records(5 * Stack::V2_FRAME_WORDS, 2, 77);
    stack_records_ok = stack_records_ok &&
        f.words[stack_record_top_word] ==
            ((5 * Stack::V2_FRAME_WORDS + 2 * Stack::V2_FIN_WORDS) | ((5 * Stack::V2_FRAME_WORDS) << 16)) &&
        f.words[stack_bci_word] == 77;
  }

  Expected expected[] = {
    { "WORD_SIZE", WORD_SIZE, false },
    { "CHUNK_END_SENTINEL", reinterpret_cast<uword>(chunk_end_sentinel()), false },
    { "SMI_TAG_SIZE", static_cast<uword>(Object::SMI_TAG_SIZE), false },
    { "SMI_TAG_MASK", Object::SMI_TAG_MASK, false },
    { "SMI_TAG", Object::SMI_TAG, false },
    { "NON_SMI_TAG_MASK", Object::NON_SMI_TAG_MASK, false },
    { "HEAP_TAG", Object::HEAP_TAG, false },
    { "ERROR_TAG", Error::ERROR_TAG, false },
    { "MIN_SMI", static_cast<uword>(Smi::MIN_SMI_VALUE), false },
    { "MAX_SMI", static_cast<uword>(Smi::MAX_SMI_VALUE), false },
    { "HEADER_WORD", static_cast<uword>(HeapObject::HEADER_OFFSET / WORD_SIZE), false },
    { "CLASS_TAG_OFFSET", static_cast<uword>(HeapObject::CLASS_TAG_OFFSET), false },
    { "CLASS_TAG_MASK", HeapObject::CLASS_TAG_MASK, false },
    { "CLASS_ID_OFFSET", static_cast<uword>(HeapObject::CLASS_ID_OFFSET), false },
    { "INSTANCE_SIZE_MASK", static_cast<uword>(Program::INSTANCE_SIZE_MASK), false },
    { "ARRAY_TAG", ARRAY_TAG, false },
    { "STRING_TAG", STRING_TAG, false },
    { "INSTANCE_TAG", INSTANCE_TAG, false },
    { "ODDBALL_TAG", ODDBALL_TAG, false },
    { "DOUBLE_TAG", DOUBLE_TAG, false },
    { "BYTE_ARRAY_TAG", BYTE_ARRAY_TAG, false },
    { "LARGE_INTEGER_TAG", LARGE_INTEGER_TAG, false },
    { "STACK_TAG", STACK_TAG, false },
    { "TASK_TAG", TASK_TAG, false },
    { "INSTANCE_FIELDS_WORD", static_cast<uword>(instance_fields_word), false },
    { "ARRAY_LENGTH_WORD", static_cast<uword>(array_length_word), false },
    { "ARRAY_ELEMENTS_WORD", static_cast<uword>(array_elements_word), false },
    { "DOUBLE_VALUE_WORD", static_cast<uword>(double_value_word), false },
    { "LARGE_INTEGER_VALUE_WORD", static_cast<uword>(large_integer_value_word), false },
    { "BYTE_ARRAY_LENGTH_WORD", static_cast<uword>(byte_array_length_word), false },
    { "BYTE_ARRAY_CONTENT_BYTE", static_cast<uword>(byte_array_content_byte), false },
    { "BYTE_ARRAY_EXTERNAL_ADDRESS_WORD", static_cast<uword>(byte_array_external_address_word), false },
    { "BYTE_ARRAY_EXTERNAL_TAG_WORD", static_cast<uword>(byte_array_external_tag_word), false },
    { "RAW_BYTE_TAG", RawByteTag, false },
    { "MAPPED_FILE_TAG", MappedFileTag, false },
    { "STRING_INTERNAL_LENGTH_BYTE", static_cast<uword>(string_internal_length_byte), false },
    { "STRING_CONTENT_BYTE", static_cast<uword>(string_content_byte), false },
    { "STRING_SENTINEL", 65535, false },
    { "STRING_HASH_CODE_BYTE", static_cast<uword>(string_hash_code_byte), false },
    { "STRING_NO_HASH_CODE", string_no_hash_code, false },
    { "STRING_EXTERNAL_LENGTH_WORD", static_cast<uword>(string_external_length_word), false },
    { "STRING_EXTERNAL_ADDRESS_WORD", static_cast<uword>(string_external_address_word), false },
    { "CARD_SIZE_LOG_2", static_cast<uword>(GcMetadata::CARD_SIZE_LOG_2), false },
    { "NEW_SPACE_POINTERS", GcMetadata::NEW_SPACE_POINTERS, false },
    { "STACK_LENGTH_WORD", static_cast<uword>(stack_length_word), false },
    { "STACK_TOP_WORD", static_cast<uword>(stack_top_word), false },
    { "STACK_RECORD_TOP_WORD", static_cast<uword>(stack_record_top_word), false },
    { "STACK_BCI_WORD", static_cast<uword>(stack_bci_word), false },
    { "STACK_FRAME_TOP_SHIFT", static_cast<uword>(Stack::V2_FRAME_TOP_SHIFT), false },
    { "MAX_STACK_LENGTH", static_cast<uword>(Stack::V2_MAX_LENGTH), false },
    { "WORD_BITS", static_cast<uword>(WORD_BIT_SIZE), false },
    { "FRAME_WORDS", static_cast<uword>(Stack::V2_FRAME_WORDS), false },
    { "FRAME_METHOD", static_cast<uword>(Stack::V2_FRAME_METHOD), false },
    { "FRAME_RET", static_cast<uword>(Stack::V2_FRAME_RET), false },
    { "FRAME_BASE", static_cast<uword>(Stack::V2_FRAME_BASE), false },
    { "FRAME_HANDLER", static_cast<uword>(Stack::V2_FRAME_HANDLER), false },
    { "FRAME_HANDLER_BCI", static_cast<uword>(Stack::V2_FRAME_HANDLER_BCI), false },
    { "STACK_RESERVE", static_cast<uword>(Stack::V2_STACK_RESERVE), false },
    { "FIN_WORDS", static_cast<uword>(Stack::V2_FIN_WORDS), false },
    { "FIN_FRAME", static_cast<uword>(Stack::V2_FIN_FRAME), false },
    { "FIN_HEIGHT", static_cast<uword>(Stack::V2_FIN_HEIGHT), false },
    { "FIN_RESUME", static_cast<uword>(Stack::V2_FIN_RESUME), false },
    { "FIN_TARGET", static_cast<uword>(Stack::V2_FIN_TARGET), false },
    { "FIN_TARGET_HEIGHT", static_cast<uword>(Stack::V2_FIN_TARGET_HEIGHT), false },
    { "ROOT_NULL", Program::null_object_INDEX, false },
    { "ROOT_TRUE", Program::true_object_INDEX, false },
    { "ROOT_FALSE", Program::false_object_INDEX, false },
    { "ROOT_OUT_OF_MEMORY_ERROR", Program::out_of_memory_error_INDEX, false },
    { "ROOT_ERROR", Program::ERROR_INDEX, false },
    { "ROOT_STACK_OVERFLOW", Program::STACK_OVERFLOW_INDEX, false },
    { "ROOT_EMPTY_ARRAY", Program::empty_array_INDEX, false },
    { "ROOT_ALLOCATION_FAILED", Program::ALLOCATION_FAILED_INDEX, false },
    { "ROOT_DIVISION_BY_ZERO", Program::DIVISION_BY_ZERO_INDEX, false },
    { "ROOT_ILLEGAL_UTF_8", Program::ILLEGAL_UTF_8_INDEX, false },
    { "ROOT_INVALID_ARGUMENT", Program::INVALID_ARGUMENT_INDEX, false },
    { "ROOT_NEGATIVE_ARGUMENT", Program::NEGATIVE_ARGUMENT_INDEX, false },
    { "ROOT_OUT_OF_BOUNDS", Program::OUT_OF_BOUNDS_INDEX, false },
    { "ROOT_OUT_OF_RANGE", Program::OUT_OF_RANGE_INDEX, false },
    { "ROOT_PERMISSION_DENIED", Program::PERMISSION_DENIED_INDEX, false },
    { "ROOT_WRONG_OBJECT_TYPE", Program::WRONG_OBJECT_TYPE_INDEX, false },
    { "ROOT_WRONG_BYTES_TYPE", Program::WRONG_BYTES_TYPE_INDEX, false },
    { "ROOT_COUNT", Program::ROOT_COUNT, false },
    { "BUILTIN_COUNT", Program::BUILTIN_CLASS_IDS_COUNT, false },
    { "ENTRY_POINT_COUNT", Program::ENTRY_POINTS_COUNT, false },
    { "INVOKE_OFFSET_COUNT", static_cast<uword>(INVOKE_SIZE - INVOKE_EQ + 1), false },
    { "BUILTIN_STRING", Program::string_class_id_INDEX, false },
    { "BUILTIN_ARRAY", Program::array_class_id_INDEX, false },
    { "BUILTIN_BYTE_ARRAY", Program::byte_array_class_id_INDEX, false },
    { "BUILTIN_STRING_SLICE", Program::string_slice_class_id_INDEX, false },
    { "BUILTIN_STRING_BYTE_SLICE", Program::string_byte_slice_class_id_INDEX, false },
    { "BUILTIN_DOUBLE", Program::double_class_id_INDEX, false },
    { "BUILTIN_LARGE_INTEGER", Program::large_integer_class_id_INDEX, false },
    { "BUILTIN_BYTE_ARRAY_COW", Program::byte_array_cow_class_id_INDEX, false },
    { "BUILTIN_BYTE_ARRAY_SLICE", Program::byte_array_slice_class_id_INDEX, false },
    { "BUILTIN_LIST", Program::list_class_id_INDEX, false },
    { "BUILTIN_OBJECT", Program::object_class_id_INDEX, false },
    { "BUILTIN_SMI", Program::smi_class_id_INDEX, false },
    { "BUILTIN_TASK", Program::task_class_id_INDEX, false },
    { "BUILTIN_LARGE_ARRAY", Program::large_array_class_id_INDEX, false },
    { "BUILTIN_LAZY_INITIALIZER", Program::lazy_initializer_class_id_INDEX, false },
    { "BUILTIN_EXCEPTION", Program::exception_class_id_INDEX, false },
    { "ENTRY_MAIN", Program::entry_main_INDEX, false },
    { "ENTRY_SPAWN", Program::entry_spawn_INDEX, false },
    { "ENTRY_TASK", Program::entry_task_INDEX, false },
    { "ENTRY_RUN_GLOBAL_INITIALIZER", Program::run_global_initializer_INDEX, false },
    { "ARRAYLET_SIZE", static_cast<uword>(Array::ARRAYLET_SIZE), false },
    { "RESULT_PREEMPTED", Interpreter::Result::PREEMPTED, false },
    { "RESULT_YIELDED", Interpreter::Result::YIELDED, false },
    { "RESULT_TERMINATED", Interpreter::Result::TERMINATED, false },
    { "RESULT_RESET", Interpreter::Result::RESET, false },
    { "RESULT_DEEP_SLEEP", Interpreter::Result::DEEP_SLEEP, false },
    // Interpreter::PREEMPTION_MARKER is private; it is UINTPTR_MAX.
    { "PREEMPTION_MARKER", UINTPTR_MAX, false },
    { "V2_OK", TOIT_V2_OK, false },
    { "V2_STACK_OVERFLOW", TOIT_V2_STACK_OVERFLOW, false },
    { "V2_OUT_OF_MEMORY", TOIT_V2_OUT_OF_MEMORY, false },
    { "V2_PRIMITIVE_SUCCESS", TOIT_V2_PRIMITIVE_SUCCESS, false },
    { "V2_PRIMITIVE_FAILURE", TOIT_V2_PRIMITIVE_FAILURE, false },
    { "V2_PRIMITIVE_THROW", TOIT_V2_PRIMITIVE_THROW, false },
    { "V2_PRIMITIVE_MISSING", TOIT_V2_PRIMITIVE_MISSING, false },
    { "V2_PRIMITIVE_FOUND", TOIT_V2_PRIMITIVE_FOUND, false },
    { "V2_PRIMITIVE_ABSENT", TOIT_V2_PRIMITIVE_ABSENT, false },
    { "V2_ACCEPTED", TOIT_V2_ACCEPTED, false },
    { "V2_TRUSTED", TOIT_V2_TRUSTED, false },
    { "V2_REPORT_STUCK", TOIT_V2_REPORT_STUCK, false },
    { "V2_REPORT_UNCAUGHT", TOIT_V2_REPORT_UNCAUGHT, false },
    { "V2_REPORT_TASK_RETURNED", TOIT_V2_REPORT_TASK_RETURNED, false },
    { "V2_REPORT_TRACE", TOIT_V2_REPORT_TRACE, false },
    { "V2_MESSAGE_NONE", TOIT_V2_MESSAGE_NONE, false },
    { "V2_MESSAGE_WORD", TOIT_V2_MESSAGE_WORD, false },
    { "V2_MESSAGE_ARRAY", TOIT_V2_MESSAGE_ARRAY, false },
    { "V2_MESSAGE_PRIMITIVE", TOIT_V2_MESSAGE_PRIMITIVE, false },
    { "V2_MESSAGE_MAX_WORDS", TOIT_V2_MESSAGE_MAX_WORDS, false },
    { "KIND_METHOD", V2_KIND_METHOD, false },
    { "KIND_FIELD_ACCESSOR", V2_KIND_FIELD_ACCESSOR, false },
    { "KIND_LAMBDA", V2_KIND_LAMBDA, false },
    { "KIND_BLOCK", V2_KIND_BLOCK, false },
    { "NO_VALUE", V2_NO_VALUE, false },
    { "BLOCK_SLOT_BITS", Stack::V2_FRAME_TOP_SHIFT, false },
    { "FAILURE_LITERALS", V2_FAILURE_LITERALS, false },
    { "MAX_INSTRUCTION_LENGTH", max_instruction_length, false },
    { "MAX_TABLE", V2_MAX_TABLE, false },
    { "TASK_STACK_FIELD", static_cast<uword>(Task::STACK_INDEX), false },
    { "TASK_ID_FIELD", static_cast<uword>(Task::ID_INDEX), false },
    { "RECORD_ENTRY_SHIFT", V2_RECORD_ENTRY_SHIFT, false },
    { "RECORD_ARITY_MASK", V2_RECORD_ARITY_MASK, false },
    { "KIND_MASK", V2_KIND_MASK, false },
    { "KIND_SINGLE", V2_KIND_SINGLE, false },
    { "SELECTOR_BACK", V2_SELECTOR_BACK, false },
    { "RECV_START_BACK", V2_RECV_START_BACK, false },
    { "RECV_END_BACK", V2_RECV_END_BACK, false },
    { "ACCESSOR_AUX_BACK", V2_ACCESSOR_AUX_BACK, false },
    { "LAMBDA_AUX_BACK", V2_LAMBDA_AUX_BACK, false },
    { "MAX_BYTECODES", V2_MAX_BYTECODES, false },
#define FIELD(prefix, type, name) { prefix #name, offsetof(type, name), false },
    { "PROGRAM_SIZE", sizeof(toit_v2_program), false },
    FIELD("PROGRAM_", toit_v2_program, bytecodes) FIELD("PROGRAM_", toit_v2_program, methods)
    FIELD("PROGRAM_", toit_v2_program, dispatch) FIELD("PROGRAM_", toit_v2_program, class_bits)
    FIELD("PROGRAM_", toit_v2_program, class_check_ids)
    FIELD("PROGRAM_", toit_v2_program, interface_check_offsets)
    FIELD("PROGRAM_", toit_v2_program, invoke_offsets) FIELD("PROGRAM_", toit_v2_program, entry_points)
    FIELD("PROGRAM_", toit_v2_program, builtin_class_ids) FIELD("PROGRAM_", toit_v2_program, roots)
    FIELD("PROGRAM_", toit_v2_program, literals) FIELD("PROGRAM_", toit_v2_program, globals)
    FIELD("PROGRAM_", toit_v2_program, program_heap_start) FIELD("PROGRAM_", toit_v2_program, program_heap_size)
    FIELD("PROGRAM_", toit_v2_program, remembered_set_bias)
    FIELD("PROGRAM_", toit_v2_program, global_max_height)
    FIELD("PROGRAM_", toit_v2_program, stack_array_word)
    { "CONTEXT_SIZE", sizeof(toit_v2_context), false },
    FIELD("CONTEXT_", toit_v2_context, process) FIELD("CONTEXT_", toit_v2_context, program)
    FIELD("CONTEXT_", toit_v2_context, watermark) FIELD("CONTEXT_", toit_v2_context, preempt_a_lot)
    FIELD("CONTEXT_", toit_v2_context, accepted)
    FIELD("CONTEXT_", toit_v2_context, core_arities) FIELD("CONTEXT_", toit_v2_context, core_arities_length)
    FIELD("CONTEXT_", toit_v2_context, epoch)
    FIELD("CONTEXT_", toit_v2_context, unchecked)
    FIELD("CONTEXT_", toit_v2_context, new_space_top) FIELD("CONTEXT_", toit_v2_context, new_space_limit)
    FIELD("CONTEXT_", toit_v2_context, result_state) FIELD("CONTEXT_", toit_v2_context, result_value)
#undef FIELD
  };
  const int expected_count = sizeof(expected) / sizeof(expected[0]);

  // Opcode numbers: format 1 names, plus the format-2 renames.
  struct Op { const char* name; int value; };
  static const Op ops[] = {
#define OP(name, length, format, print) { "OP_" #name, name },
    BYTECODES(OP)
#undef OP
    { "OP_TRY", LINK },
    { "OP_LOAD_FIELD_THIS", UNLINK },
    { "OP_STORE_FIELD_THIS", NON_LOCAL_RETURN_WIDE },
  };

  // Facts without a named constant.
  if (sizeof(uword) != sizeof(void*) || sizeof(Object*) != sizeof(uword) ||
      !(WORD_SIZE == 8 || WORD_SIZE == 4) || sizeof(uword) != WORD_SIZE) {
    printf("FAIL: the core assumes 32-bit or 64-bit words the size of pointers\n");
    failures++;
  }
  // Block references (slot bits) and the Stack header's packed record and
  // frame tops need stack positions below 2^16.
  if (Stack::max_length() >= Stack::V2_MAX_LENGTH) {
    printf("FAIL: Stack::max_length() does not fit 16 bits\n");
    failures++;
  }
  if (!stack_records_ok) {
    printf("FAIL: Stack record top, finally-record count and bci encoding\n");
    failures++;
  }
  if (sizeof(std::atomic<Object**>) != sizeof(uword)) {
    printf("FAIL: the watermark is not a plain word\n");
    failures++;
  }
  if (LOAD_LOCAL_5 - LOAD_LOCAL_0 != 5 || BRANCH_BACK_IF_NOT_NULL - BRANCH_BACK != 3 ||
      BRANCH_IF_NOT_NULL - BRANCH != 3 || INVOKE_AT_PUT - INVOKE_EQ != 17) {
    printf("FAIL: opcode ranges\n");
    failures++;
  }
  // The header class-id field may be negative (CLASS_ID_MASK is all ones):
  // the core uses an arithmetic shift.
  if (HeapObject::CLASS_ID_MASK != static_cast<uword>(-1)) {
    printf("FAIL: CLASS_ID_MASK\n");
    failures++;
  }
  // The core module's primitive table (verified/core/src/prims/index.rs).
  {
    struct Prim { const char* name; int arity; };
    static const Prim prims[] = {
#define PRIM(name, arity) { #name, arity },
      MODULE_CORE(PRIM)
#undef PRIM
    };
    const uword prim_count = sizeof(prims) / sizeof(prims[0]);
    if (toit_vcore_prim_count() != prim_count) fail("core primitive count", toit_vcore_prim_count(), prim_count);
    for (uword i = 0; i < toit_vcore_prim_count(); i++) {
      const char* name;
      uword index, arity;
      if (!toit_vcore_prim_entry(i, &name, &index, &arity) || index >= prim_count ||
          strcmp(prims[index].name, name) != 0) {
        printf("FAIL: core primitive entry %lu\n", static_cast<unsigned long>(i));
        failures++;
      } else if (static_cast<uword>(prims[index].arity) != arity) {
        fail(name, arity, prims[index].arity);
      }
    }
  }
  // Opcode lengths.
  for (int op = 0; op < V2_OPCODE_COUNT; op++) {
    uword rust = toit_vcore_opcode_length(op);
    if (rust != V2_OPCODE_LENGTHS[op]) fail("opcode length", rust, V2_OPCODE_LENGTHS[op]);
  }

  uword count = toit_vcore_layout_count();
  for (uword i = 0; i < count; i++) {
    const char* name;
    uword value;
    if (!toit_vcore_layout_entry(i, &name, &value)) {
      printf("FAIL: entry %lu unreadable\n", static_cast<unsigned long>(i));
      failures++;
      continue;
    }
    bool found = false;
    if (strncmp(name, "OP_", 3) == 0) {
      for (const Op& op : ops) {
        if (strcmp(op.name, name) != 0) continue;
        found = true;
        if (static_cast<uword>(op.value) != value) fail(name, value, op.value);
      }
    } else {
      for (int j = 0; j < expected_count; j++) {
        if (strcmp(expected[j].name, name) != 0) continue;
        found = true;
        expected[j].seen = true;
        if (expected[j].value != value) fail(name, value, expected[j].value);
      }
    }
    if (!found) {
      printf("FAIL: Rust constant %s has no C++ counterpart in the check\n", name);
      failures++;
    }
  }
  for (int j = 0; j < expected_count; j++) {
    if (!expected[j].seen) {
      printf("FAIL: %s not exported by the Rust core\n", expected[j].name);
      failures++;
    }
  }

  // The verifier's C ABI (verified/vmverify/src/ffi.rs, src/verifier_v2.h).
#define VFIELD(prefix, type, field) { prefix #field, offsetof(type, field), false },
  Expected vexpected[] = {
    { "VMVERIFY_INPUT_SIZE", sizeof(toit_vmverify_input), false },
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, program)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, prim_counts)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, prim_module_count)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, prim_arities)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, prim_arities_length)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, trusted)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, certificate)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, certificate_length)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, progress)
    VFIELD("VMVERIFY_INPUT_", toit_vmverify_input, progress_context)
    { "VMVERIFY_RESULT_SIZE", sizeof(toit_vmverify_result), false },
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, code)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, method)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, offset)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, objects)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, convert_ns)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, heap_ns)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, infer_ns)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, check_ns)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, peak_bytes)
    VFIELD("VMVERIFY_RESULT_", toit_vmverify_result, message)
    { "VMVERIFY_MESSAGE_SIZE", static_cast<uword>(TOIT_VMVERIFY_MESSAGE_SIZE), false },
    { "VMVERIFY_ACCEPTED", TOIT_VMVERIFY_ACCEPTED, false },
    { "VMVERIFY_MALFORMED", TOIT_VMVERIFY_MALFORMED, false },
    { "VMVERIFY_HEAP", TOIT_VMVERIFY_HEAP, false },
    { "VMVERIFY_TABLES", TOIT_VMVERIFY_TABLES, false },
    { "VMVERIFY_METHOD", TOIT_VMVERIFY_METHOD, false },
    { "VMVERIFY_CERTIFICATE", TOIT_VMVERIFY_CERTIFICATE, false },
    { "VMVERIFY_NO_CERTIFICATE", TOIT_VMVERIFY_NO_CERTIFICATE, false },
    { "VMVERIFY_INTERNAL", TOIT_VMVERIFY_INTERNAL, false },
    { "VMVERIFY_OUT_OF_MEMORY", TOIT_VMVERIFY_OUT_OF_MEMORY, false },
  };
#undef VFIELD
  const int vexpected_count = sizeof(vexpected) / sizeof(vexpected[0]);
  uword vcount = toit_vmverify_layout_count();
  for (uword i = 0; i < vcount; i++) {
    const char* name;
    uword value;
    if (!toit_vmverify_layout_entry(i, &name, &value)) {
      printf("FAIL: verifier entry %lu unreadable\n", static_cast<unsigned long>(i));
      failures++;
      continue;
    }
    bool found = false;
    for (int j = 0; j < vexpected_count; j++) {
      if (strcmp(vexpected[j].name, name) != 0) continue;
      found = true;
      vexpected[j].seen = true;
      if (vexpected[j].value != value) fail(name, value, vexpected[j].value);
    }
    if (!found) {
      printf("FAIL: verifier constant %s has no C++ counterpart in the check\n", name);
      failures++;
    }
  }
  for (int j = 0; j < vexpected_count; j++) {
    if (!vexpected[j].seen) {
      printf("FAIL: %s not exported by the verifier\n", vexpected[j].name);
      failures++;
    }
  }

  // The verifier gets the VM's primitive arities at run time (verifier_v2.cc);
  // the generated table (verified/spec/src/v2/prim_arity.rs), which the dump
  // path uses, must agree with them.
  struct Module { const char* name; int count; };
  static const uint8 arities[] = {
#define ARITY_ONE(name, arity) arity,
#define MODULE_ARITIES(name, entries) entries(ARITY_ONE)
    MODULES(MODULE_ARITIES)
#undef MODULE_ARITIES
#undef ARITY_ONE
  };
  static const Module modules[] = {
#define MODULE_INFO(name, entries) { #name, 0 entries(MODULE_PRIMITIVE_COUNT_ONE) },
    MODULES(MODULE_INFO)
#undef MODULE_INFO
  };
  int at = 0;
  int module_count = sizeof(modules) / sizeof(modules[0]);
  for (int m = 0; m < module_count; m++) {
    for (int i = 0; i < modules[m].count; i++) {
      word generated = toit_vmverify_generated_arity(m, i);
      if (generated != arities[at + i]) {
        printf("FAIL: primitive %s #%d: generated arity %ld, VM %d\n", modules[m].name, i,
               static_cast<long>(generated), arities[at + i]);
        failures++;
      }
    }
    if (toit_vmverify_generated_arity(m, modules[m].count) != -1) {
      printf("FAIL: primitive module %s: the generated table has more primitives\n", modules[m].name);
      failures++;
    }
    at += modules[m].count;
  }
  if (toit_vmverify_generated_arity(module_count, 0) != -1) {
    printf("FAIL: the generated primitive table has more modules\n");
    failures++;
  }

  if (failures != 0) {
    printf("verified core layout check: %d failure(s)\n", failures);
    return 1;
  }
  printf("verified core layout check: %lu constants, %lu verifier constants, %d primitive modules, OK\n",
         static_cast<unsigned long>(count), static_cast<unsigned long>(vcount), module_count);
  return 0;
}

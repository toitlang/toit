// Copyright (C) 2021 Toitware ApS.
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

#include "encoder.h"
#include "entropy_mixer.h"
#include "flags.h"
#include "heap.h"
#include "heap_report.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "process_group.h"
#include "process.h"
#include "scheduler.h"
#include "top.h"
#include "vm.h"

#ifndef RAW
#include "compiler/compiler.h"
#endif

#include <math.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <cinttypes>
#include <errno.h>
#include <inttypes.h>
#include <sys/time.h>

#ifdef TOIT_FREERTOS
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_spi_flash.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#elif defined(TOIT_POSIX)
#include <sys/resource.h>
#endif

#ifdef __x86_64__
#include <emmintrin.h>  // SSE2 primitives.
typedef __m128i uint128_t;
#endif

namespace toit {

MODULE_IMPLEMENTATION(core, MODULE_CORE)

PRIMITIVE(write_string_on_stdout) {
  ARGS(cstring, message, bool, add_newline);
  fprintf(stdout, "%s%s", message, add_newline ? "\n" : "");
  fflush(stdout);
  return _raw_message;
}

PRIMITIVE(write_string_on_stderr) {
  ARGS(cstring, message, bool, add_newline);
  fprintf(stderr, "%s%s", message, add_newline ? "\n" : "");
  fflush(stderr);
  return _raw_message;
}

PRIMITIVE(main_arguments) {
  uint8* arguments = process->main_arguments();
  if (!arguments) return process->program()->empty_array();

  MessageDecoder decoder(process, arguments);
  Object* decoded = decoder.decode();
  if (decoder.allocation_failed()) {
    decoder.remove_disposing_finalizers();
    ALLOCATION_FAILED;
  }

  process->clear_main_arguments();
  free(arguments);
  decoder.register_external_allocations();
  return decoded;
}

PRIMITIVE(spawn_arguments) {
  uint8* arguments = process->spawn_arguments();
  if (!arguments) return process->program()->empty_array();

  MessageDecoder decoder(process, arguments);
  Object* decoded = decoder.decode();
  if (decoder.allocation_failed()) {
    decoder.remove_disposing_finalizers();
    ALLOCATION_FAILED;
  }

  process->clear_spawn_arguments();
  free(arguments);
  decoder.register_external_allocations();
  return decoded;
}

PRIMITIVE(spawn_method) {
  Method method = process->spawn_method();
  int id = method.is_valid()
      ? process->program()->absolute_bci_from_bcp(method.header_bcp())
      : -1;
  return Smi::from(id);
}

PRIMITIVE(spawn) {
  ARGS(int, priority, Object, entry, Object, arguments)
  if (priority != -1 && (priority < 0 || priority > 0xff)) OUT_OF_RANGE;
  if (!is_smi(entry)) WRONG_TYPE;

  int method_id = Smi::cast(entry)->value();
  ASSERT(method_id != -1);
  Method method(process->program()->bytecodes, method_id);

  InitialMemoryManager manager;
  if (!manager.allocate()) ALLOCATION_FAILED;

  unsigned size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) {
      return size_encoder.create_error_object(process);
    }
    size = size_encoder.size();
  }

  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  if (buffer == null) MALLOC_FAILED;

  MessageEncoder encoder(process, buffer);
  if (!encoder.encode(arguments)) {
    encoder.free_copied();
    free(buffer);
    // Should not happen, but just in case, throw "ERROR".
    OTHER_ERROR;
  }

  int pid = VM::current()->scheduler()->spawn(
      process->program(),
      process->group(),
      priority,
      method,
      buffer,
      manager.initial_chunk);
  if (pid == Scheduler::INVALID_PROCESS_ID) {
    encoder.free_copied();
    free(buffer);
    MALLOC_FAILED;
  }

  manager.dont_auto_free();
  return Smi::from(pid);
}

PRIMITIVE(get_generic_resource_group) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  SimpleResourceGroup* resource_group = _new SimpleResourceGroup(process);
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(process_signal_kill) {
  ARGS(int, target_id);

  return BOOL(VM::current()->scheduler()->signal_process(process, target_id, Process::KILL));
}

PRIMITIVE(process_current_id) {
  return Smi::from(process->id());
}

PRIMITIVE(process_get_priority) {
  ARGS(int, pid);
  int priority = VM::current()->scheduler()->get_priority(pid);
  if (priority < 0) INVALID_ARGUMENT;
  return Smi::from(priority);
}

PRIMITIVE(process_set_priority) {
  ARGS(int, pid, int, priority);
  if (priority < 0 || priority > 0xff) OUT_OF_RANGE;
  bool success = VM::current()->scheduler()->set_priority(pid, priority);
  if (!success) INVALID_ARGUMENT;
  return process->program()->null_object();
}

PRIMITIVE(object_class_id) {
  ARGS(Object, arg);
  return is_smi(arg)
     ? process->program()->smi_class_id()
     : HeapObject::cast(arg)->class_id();
}

PRIMITIVE(compare_to) {
  ARGS(Object, lhs, Object, rhs);
  int result = Interpreter::compare_numbers(lhs, rhs);
  if (result == Interpreter::COMPARE_FAILED) {
    INVALID_ARGUMENT;
  }
  result &= Interpreter::COMPARE_RESULT_MASK;
  return Smi::from(result + Interpreter::COMPARE_RESULT_BIAS);
}

PRIMITIVE(min_special_compare_to) {
  ARGS(Object, lhs, Object, rhs);
  int result = Interpreter::compare_numbers(lhs, rhs);
  if (result == Interpreter::COMPARE_FAILED) {
    INVALID_ARGUMENT;
  }
  result &= Interpreter::COMPARE_FLAG_LESS_FOR_MIN;
  return BOOL(result != 0);
}

#define SMI_COMPARE(op) { \
  ARGS(word, receiver, Object, arg); \
  if (is_smi(arg)) return BOOL(receiver op Smi::cast(arg)->value()); \
  if (!is_large_integer(arg)) WRONG_TYPE; \
  return BOOL(((int64) receiver) op LargeInteger::cast(arg)->value()); \
}

#define DOUBLE_COMPARE(op) { \
  ARGS(double, receiver, double, arg); \
  return BOOL(receiver op arg); \
}

#define LARGE_INTEGER_COMPARE(op) { \
  ARGS(LargeInteger, receiver, Object, arg); \
  if (is_smi(arg)) return BOOL(receiver->value() op (int64) Smi::cast(arg)->value()); \
  if (!is_large_integer(arg)) WRONG_TYPE; \
  return BOOL(receiver->value() op LargeInteger::cast(arg)->value()); \
}

PRIMITIVE(smi_less_than)             SMI_COMPARE(<)
PRIMITIVE(smi_less_than_or_equal)    SMI_COMPARE(<=)
PRIMITIVE(smi_greater_than)          SMI_COMPARE(>)
PRIMITIVE(smi_greater_than_or_equal) SMI_COMPARE(>=)
PRIMITIVE(smi_equals)                SMI_COMPARE(==)

PRIMITIVE(float_less_than)             DOUBLE_COMPARE(<)
PRIMITIVE(float_less_than_or_equal)    DOUBLE_COMPARE(<=)
PRIMITIVE(float_greater_than)          DOUBLE_COMPARE(>)
PRIMITIVE(float_greater_than_or_equal) DOUBLE_COMPARE(>=)
PRIMITIVE(float_equals)                DOUBLE_COMPARE(==)

PRIMITIVE(large_integer_less_than)             LARGE_INTEGER_COMPARE(<)
PRIMITIVE(large_integer_less_than_or_equal)    LARGE_INTEGER_COMPARE(<=)
PRIMITIVE(large_integer_greater_than)          LARGE_INTEGER_COMPARE(>)
PRIMITIVE(large_integer_greater_than_or_equal) LARGE_INTEGER_COMPARE(>=)
PRIMITIVE(large_integer_equals)                LARGE_INTEGER_COMPARE(==)

PRIMITIVE(byte_array_is_valid_string_content) {
  ARGS(Blob, bytes, int, start, int, end);
  if (!(0 <= start && start <= end && end <= bytes.length())) OUT_OF_BOUNDS;
  return BOOL(Utils::is_valid_utf_8(bytes.address() + start, end - start));
}

PRIMITIVE(byte_array_convert_to_string) {
  ARGS(Blob, bytes, int, start, int, end);
  if (!(0 <= start && start <= end && end <= bytes.length())) OUT_OF_BOUNDS;
  if (!Utils::is_valid_utf_8(bytes.address() + start, end - start)) ILLEGAL_UTF_8;
  return process->allocate_string_or_error(char_cast(bytes.address()) + start, end - start);
}

PRIMITIVE(blob_index_of) {
  ARGS(Blob, bytes, int, byte, int, from, int, to);
  if (!(0 <= from && from <= to && to <= bytes.length())) OUT_OF_BOUNDS;
#if defined(__x86_64__) && !defined(__SANITIZE_THREAD__)
  const uint8* address = bytes.address();
  // Algorithm from https://github.com/erikcorry/struhchuh.
  // Search for "*" using only aligned SSE2 128 bit loads. This may load data
  // either side of the string, but can never cause a fault because the loads are
  // in 128 bit sections also covered by the string and the fault hardware works
  // at a higher granularity.  Threadsanitizer doesn't understand this and reports
  // use-after-frees.
  int last_bits = reinterpret_cast<uintptr_t>(address + from) & 15;
  // The movemask_epi8 instruction takes the top bit of each of the 16 bytes and
  // puts them in the low 16 bits of the register, so we use a 16 bit mask here.
  int alignment_mask = 0xffff << last_bits;
  // Takes the byte we are searching for and duplicate it over all 16 bytes of
  // the 128 bit value.
  const uint128_t mask = _mm_set1_epi8(byte);
  for (int i = from - last_bits; i < to; i += 16) {
    // Load aligned to a 128 bit XMM2 register.
    uint128_t raw = *reinterpret_cast<const uint128_t*>(address + i);
    // Puts 0xff or 0x00 in the corresponding bytes depending on whether the
    // bytes in the input are equal. PCMPEQB.
    uint128_t comparison = _mm_cmpeq_epi8(raw, mask);
    // Takes the top bit of each byte and puts it in the corresponding bit of a
    // normal integer.  PMOVMSKB.
    int bits = _mm_movemask_epi8(comparison) & alignment_mask;
    if (bits != 0) {
      int answer = i + __builtin_ffs(bits) - 1;
      if (answer >= to) return Smi::from(-1);
      return Smi::from(answer);
    }
    // After the first operation we want to test all bytes for subsequent
    // operations.
    alignment_mask = 0xffff;
  }
  return Smi::from(-1);
#else
  const uint8* from_address = bytes.address() + from;
  int len = to - from;
  const uint8* value = reinterpret_cast<const uint8*>(memchr(from_address, byte, len));
  return Smi::from(value != null ? value - bytes.address() : -1);
#endif
}

static Array* get_array_from_list(Object* object, Process* process) {
  Array* result = null;
  if (is_instance(object)) {
    Instance* list = Instance::cast(object);
    if (list->class_id() == process->program()->list_class_id()) {
      Object* array_object;
      // This 'if' will fail if we are dealing with a List so large
      // that it has arraylets.
      if (is_array(array_object = list->at(0))) {
        result = Array::cast(array_object);
      }
    }
  }
  return result;
}

PRIMITIVE(crc) {
  ARGS(int64, accumulator, int, width, Blob, data, int, from, int, to, Object, table_object);
  if ((width != 0 && width < 8) || width > 64) INVALID_ARGUMENT;
  bool big_endian = width != 0;
  if (to == from) return _raw_accumulator;
  if (from < 0 || to > data.length() || from > to) OUT_OF_BOUNDS;
  Array* table = get_array_from_list(table_object, process);
  const uint8* byte_table = null;
  if (table) {
    if (table->length() != 0x100) INVALID_ARGUMENT;
  } else {
    Blob blob;
    if (!table_object->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
    if (blob.length() != 0x100) INVALID_ARGUMENT;
    byte_table = blob.address();
  }
  for (word i = from; i < to; i++) {
    uint8 byte = data.address()[i];
    uint64 index = accumulator;
    if (big_endian) index >>= width - 8;
    index = (byte ^ index) & 0xff;
    int64 entry;
    if (byte_table) {
      entry = byte_table[index];
    } else {
      Object* table_entry = table->at(index);
      if (is_smi(table_entry)) {
        entry = Smi::cast(table_entry)->value();
      } else if (is_large_integer(table_entry)) {
        entry = LargeInteger::cast(table_entry)->value();
      } else {
        INVALID_ARGUMENT;
      }
    }
    if (big_endian) {
      accumulator = (accumulator << 8) ^ entry;
    } else {
      accumulator = (static_cast<uint64>(accumulator) >> 8) ^ entry;
    }
  }
  if ((width & 63) != 0) {
    // If width is less than 64 we have to mask the result.  For the little
    // endian case (width == 0) we don't need to mask.
    uint64 mask = 1;
    mask = (mask << (width & 63)) - 1;
    accumulator &= mask;
  }
  return Primitive::integer(accumulator, process);
}

PRIMITIVE(string_from_rune) {
  ARGS(int, rune);
  if (rune < 0 || rune > Utils::MAX_UNICODE) INVALID_ARGUMENT;
  // Don't allow surrogates.
  if (0xD800 <= rune && rune <= 0xDFFF) INVALID_ARGUMENT;
  String* result;
  if (rune <= 0x7F) {
    char buffer[] = { static_cast<char>(rune) };
    result = process->allocate_string(buffer, 1);
  } else if (rune <= 0x7FF) {
    char buffer[] = {
      static_cast<char>(0xC0 | (rune >> 6)),
      static_cast<char>(0x80 | (rune & 0x3F)),
    };
    result = process->allocate_string(buffer, 2);
  } else if (rune <= 0xFFFF) {
    char buffer[] = {
      static_cast<char>(0xE0 | (rune >> 12)),
      static_cast<char>(0x80 | ((rune >> 6)  & 0x3F)),
      static_cast<char>(0x80 | (rune & 0x3F)),
    };
    result = process->allocate_string(buffer, 3);
  } else {
    char buffer[] = {
      static_cast<char>(0xF0 | (rune >> 18)),
      static_cast<char>(0x80 | ((rune >> 12)  & 0x3F)),
      static_cast<char>(0x80 | ((rune >> 6)  & 0x3F)),
      static_cast<char>(0x80 | (rune & 0x3F)),
    };
    result = process->allocate_string(buffer, 4);
  }
  if (result == null) ALLOCATION_FAILED;
  return result;
}

PRIMITIVE(string_write_to_byte_array) {
  ARGS(Blob, source_bytes, MutableBlob, dest, int, from, int, to, int, dest_index);
  if (to == from) return _raw_dest;
  if (from < 0 || to > source_bytes.length() || from > to) OUT_OF_BOUNDS;
  if (dest_index + to - from > dest.length()) OUT_OF_BOUNDS;
  memcpy(&dest.address()[dest_index], &source_bytes.address()[from], to - from);
  return _raw_dest;
}

PRIMITIVE(put_uint_big_endian) {
  ARGS(Object, unused, MutableBlob, dest, int, width, int, offset, int64, value);
  USE(unused);
  unsigned unsigned_width = width;
  unsigned unsigned_offset = offset;
  unsigned length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width > 9 || unsigned_offset + unsigned_width > length) {
    OUT_OF_BOUNDS;
  }
  for (int i = width - 1; i >= 0; i--) {
    dest.address()[offset + i] = value;
    value >>= 8;
  }
  return process->program()->null_object();
}

PRIMITIVE(put_uint_little_endian) {
  ARGS(Object, unused, MutableBlob, dest, int, width, int, offset, int64, value);
  USE(unused);
  unsigned width_minus_1 = width - 1;  // This means width 0 is rejected.
  unsigned unsigned_offset = offset;
  unsigned length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || width_minus_1 >= 8 || unsigned_offset + width_minus_1 >= length) {
    OUT_OF_BOUNDS;
  }
  for (unsigned i = 0; i <= width_minus_1; i++) {
    dest.address()[offset + i] = value;
    value >>= 8;
  }
  return process->program()->null_object();
}

PRIMITIVE(put_float_32_little_endian) {
  ARGS(Object, unused, MutableBlob, dest, int, offset, double, value);
  USE(unused);
  unsigned unsigned_offset = offset;
  unsigned length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_offset + 4 >= length) {
    OUT_OF_BOUNDS;
  }
  float raw = value;
  memcpy(dest.address() + offset, &raw, sizeof raw);
  return process->program()->null_object();
}

PRIMITIVE(put_float_64_little_endian) {
  ARGS(Object, unused, MutableBlob, dest, int, offset, double, value);
  USE(unused);
  unsigned unsigned_offset = offset;
  unsigned length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_offset + 8 >= length) {
    OUT_OF_BOUNDS;
  }
  memcpy(dest.address() + offset, &value, sizeof value);
  return process->program()->null_object();
}

PRIMITIVE(read_uint_big_endian) {
  ARGS(Object, unused, Blob, source, int, width, int, offset);
  USE(unused);
  unsigned unsigned_width = width;
  unsigned unsigned_offset = offset;
  unsigned length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width > 8 || unsigned_offset + unsigned_width > length) {
    OUT_OF_BOUNDS;
  }
  uint64 value = 0;
  for (int i = 0; i < width; i++) {
    value <<= 8;
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_uint_little_endian) {
  ARGS(Object, unused, Blob, source, int, width, int, offset);
  USE(unused);
  unsigned unsigned_width = width;
  unsigned unsigned_offset = offset;
  unsigned length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width > 8 || unsigned_offset + unsigned_width > length) {
    OUT_OF_BOUNDS;
  }
  uint64 value = 0;
  for (int i = width - 1; i >= 0; i--) {
    value <<= 8;
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_int_big_endian) {
  ARGS(Object, unused, Blob, source, int, width, int, offset);
  USE(unused);
  unsigned width_minus_1 = width - 1;  // This means size 0 is rejected.
  unsigned unsigned_offset = offset;
  unsigned length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || width_minus_1 >= 8 || unsigned_offset + width_minus_1 >= length) {
    OUT_OF_BOUNDS;
  }
  int64 value = static_cast<int8>(source.address()[offset]);  // Sign extend.
  for (unsigned i = 1; i <= width_minus_1; i++) {
    value <<= 8;
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_int_little_endian) {
  ARGS(Object, unused, Blob, source, int, width, int, offset);
  USE(unused);
  unsigned width_minus_1 = width - 1;  // This means size 0 is rejected.
  unsigned unsigned_offset = offset;
  unsigned length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || width_minus_1 >= 8 || unsigned_offset + width_minus_1 >= length) {
    OUT_OF_BOUNDS;
  }
  int64 value = static_cast<int8>(source.address()[offset + width_minus_1]);  // Sign extend.
  for (unsigned i = width_minus_1; i != 0; i--) {
    value <<= 8;
    value |= source.address()[offset + i - 1];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(command) {
  if (Flags::program_name == null) return process->program()->null_object();
  return process->allocate_string_or_error(Flags::program_name);
}

PRIMITIVE(smi_add) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::cast(arg)->value();
    if ((receiver > 0) && (other > Smi::MAX_SMI_VALUE - receiver)) goto overflow;
    if ((receiver < 0) && (other < Smi::MIN_SMI_VALUE - receiver)) goto overflow;
    return Smi::from(receiver + other);
  }
  if (!is_large_integer(arg)) WRONG_TYPE;
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::cast(arg)->value() : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver + other, process);
}

PRIMITIVE(smi_subtract) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::cast(arg)->value();
    if ((receiver < 0) && (other > Smi::MAX_SMI_VALUE + receiver)) goto overflow;
    if ((receiver > 0) && (other < Smi::MIN_SMI_VALUE + receiver)) goto overflow;
    return Smi::from(receiver - other);
  }
  if (!is_large_integer(arg)) WRONG_TYPE;
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::cast(arg)->value() : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver - other, process);
}

PRIMITIVE(smi_multiply) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::cast(arg)->value();
    word result;
    if (__builtin_mul_overflow(receiver, other << 1, &result)) goto overflow;
    Smi* r = reinterpret_cast<Smi*>(result);
    ASSERT(r == Smi::from(result >> 1));
    return r;
  }
  if (!is_large_integer(arg)) WRONG_TYPE;
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::cast(arg)->value() : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver * other, process);
}

PRIMITIVE(smi_divide) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::cast(arg)->value();
    if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    return Smi::from(receiver / other);
  }
  if (!is_large_integer(arg)) WRONG_TYPE;
  int64 other = is_smi(arg) ? (int64) Smi::cast(arg)->value() : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver / other, process);
}

PRIMITIVE(smi_mod) {
  ARGS(word, receiver, Object, arg);
  if (arg == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
  if (is_smi(arg)) {
    word other = Smi::cast(arg)->value();
    if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    return Smi::from(receiver % other);
  }
  if (!is_large_integer(arg)) WRONG_TYPE;
  int64 other = is_smi(arg) ? (int64) Smi::cast(arg)->value() : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver % other, process);
}

// Signed for base 10, unsigned for bases 2, 8 or 16.
static Object* printf_style_integer_to_string(Process* process, int64 value, int base) {
  ASSERT(base == 2 || base == 8 || base == 10 || base == 16);
  char buffer[70];
  switch (base) {
    case 2: {
      char* p = buffer;
      int first_bit = value == 0 ? 0 : 63 - Utils::clz(value);
      for (int i = first_bit; i >= 0; i--) {
        *p++ = '0' + ((value >> i) & 1);
      }
      *p++ = '\0';
      break;
    }
    case 8:
      snprintf(buffer, sizeof(buffer), "%llo", value);
      break;
    case 10:
      snprintf(buffer, sizeof(buffer), "%lld", value);
      break;
    case 16:
      snprintf(buffer, sizeof(buffer), "%llx", value);
      break;
    default:
      buffer[0] = '\0';
  }
  return process->allocate_string_or_error(buffer);
}

PRIMITIVE(int64_to_string) {
  ARGS(int64, value, int, base);
  if (!(2 <= base && base <= 36)) OUT_OF_RANGE;
  if (base == 10 || (value >= 0 && (base == 2 || base == 8 || base == 16))) {
    return printf_style_integer_to_string(process, value, base);
  }
  const int BUFFER_SIZE = 70;
  char buffer[BUFFER_SIZE];
  char* p = &buffer[0];
  if (value == 0) {
    snprintf(buffer, BUFFER_SIZE, "0");
  } else {
    uint64 unsigned_value;
    char sign = '+';
    if (value < 0) {
      sign = '-';
      // This also works fine for min-int.  The negation has no effect, but the
      // correct value ends up in the unsigned variable.
      unsigned_value = -value;
    } else {
      unsigned_value = value;
    }
    p = &buffer[BUFFER_SIZE];
    *--p = '\0';
    while (unsigned_value != 0) {
      int digit = unsigned_value % base;
      unsigned_value /= base;
      if (digit < 10) {
        *--p = '0' + digit;
      } else {
        *--p = 'a' + digit - 10;
      }
    }
    if (sign == '-') {
      *--p = sign;
    }
  }
  return process->allocate_string_or_error(p);
}

PRIMITIVE(large_integer_add) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result += Smi::cast(arg)->value();
  else if (is_large_integer(arg)) result += LargeInteger::cast(arg)->value();
  else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_subtract) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result -= Smi::cast(arg)->value();
  else if (is_large_integer(arg)) result -= LargeInteger::cast(arg)->value();
  else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_multiply) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result *= Smi::cast(arg)->value();
  else if (is_large_integer(arg)) result *= LargeInteger::cast(arg)->value();
  else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_divide) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    if (Smi::cast(arg)->value() == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    result /= Smi::cast(arg)->value();
  } else if (is_large_integer(arg)) {
    ASSERT(LargeInteger::cast(arg)->value() != 0LL);
    result /= LargeInteger::cast(arg)->value();
  } else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_mod) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    if (Smi::cast(arg)->value() == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    result %= Smi::cast(arg)->value();
  } else if (is_large_integer(arg)) {
    ASSERT(LargeInteger::cast(arg)->value() != 0LL);
    result %= LargeInteger::cast(arg)->value();
  } else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_unary_minus) {
  ARGS(LargeInteger, receiver);
  return Primitive::integer(-receiver->value(), process);
}

PRIMITIVE(large_integer_not) {
  ARGS(LargeInteger, receiver);
  return Primitive::integer(~receiver->value(), process);
}

PRIMITIVE(large_integer_and) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    result &= Smi::cast(arg)->value();
  } else if (is_large_integer(arg)) {
    result &= LargeInteger::cast(arg)->value();
  } else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_or) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    result |= Smi::cast(arg)->value();
  } else if (is_large_integer(arg)) {
    result |= LargeInteger::cast(arg)->value();
  } else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_xor) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    result ^= Smi::cast(arg)->value();
  } else if (is_large_integer(arg)) {
    result ^= LargeInteger::cast(arg)->value();
  } else WRONG_TYPE;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_shift_right) {
  ARGS(LargeInteger, receiver, int64, bits_to_shift);
  if (bits_to_shift < 0) NEGATIVE_ARGUMENT;
  if (bits_to_shift >= LARGE_INT_BIT_SIZE) return Primitive::integer(receiver->value() < 0 ? -1 : 0, process);
  return Primitive::integer(receiver->value() >> bits_to_shift, process);
}

PRIMITIVE(large_integer_unsigned_shift_right) {
  ARGS(LargeInteger, receiver, int64, bits_to_shift);
  if (bits_to_shift < 0) NEGATIVE_ARGUMENT;
  if (bits_to_shift >= LARGE_INT_BIT_SIZE) return Smi::from(0);
  uint64 value = static_cast<uint64>(receiver->value());
  int64 result = static_cast<int64>(value >> bits_to_shift);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_shift_left) {
  ARGS(LargeInteger, receiver, int64, number_of_bits);
  if (number_of_bits < 0) NEGATIVE_ARGUMENT;
  if (number_of_bits >= LARGE_INT_BIT_SIZE) return Primitive::integer(0, process);
  return Primitive::integer(receiver->value() << number_of_bits, process);
}

PRIMITIVE(float_unary_minus) {
  ARGS(double, receiver);
  return Primitive::allocate_double(-receiver, process);
}

PRIMITIVE(float_add) {
  ARGS(double, receiver, double, arg);
  return Primitive::allocate_double(receiver + arg, process);
}

PRIMITIVE(float_subtract) {
  ARGS(double, receiver, double, arg);
  return Primitive::allocate_double(receiver - arg, process);
}

PRIMITIVE(float_multiply) {
  ARGS(double, receiver, double, arg);
  return Primitive::allocate_double(receiver * arg, process);
}

PRIMITIVE(float_divide) {
  ARGS(double, receiver, double, arg);
  return Primitive::allocate_double(receiver / arg, process);
}

PRIMITIVE(float_mod) {
  ARGS(double, receiver, double, arg);
  return Primitive::allocate_double(fmod(receiver, arg), process);
}

PRIMITIVE(float_round) {
  ARGS(double, receiver, int, precission);
  if (precission < 0 || precission > 15) INVALID_ARGUMENT;
  if (isnan(receiver)) OUT_OF_RANGE;
  if (receiver > pow(10,54)) return _raw_receiver;
  int factor = pow(10, precission);
  return Primitive::allocate_double(round(receiver * factor) / factor, process);
}

PRIMITIVE(int_parse) {
  ARGS(Blob, input, int, from, int, to, int, block_arg_dont_use_this);
  if (!(0 <= from && from < to && to <= input.length())) OUT_OF_RANGE;
  // Difficult cases, handled by Toit code.  If the ASCII length is always less
  // than 18 we don't have to worry about 64 bit overflow.
  if (to - from > 18) OUT_OF_RANGE;
  uint64 result = 0;
  bool negative = false;
  int index = from;
  const uint8* in = input.address();
  if (in[index] == '-') {
    negative = true;
    index++;
    if (index == to) INVALID_ARGUMENT;
  }
  for (; index < to; index++) {
    char c = in[index];
    if ('0' <= c && c <= '9') {
      result *= 10;
      result += c - '0';
    } else if (c == '_') {
      if (index == from || index == to - 1 || (negative && index == from + 1)) INVALID_ARGUMENT;
    } else {
      INVALID_ARGUMENT;
    }
  }
  return Primitive::integer(negative ? -result : result, process);
}

PRIMITIVE(float_parse) {
  ARGS(Blob, input, int, from, int, to);
  if (!(0 <= from && from < to && to <= input.length())) OUT_OF_RANGE;
  const char* from_ptr = char_cast(input.address() + from);
  // strtod removes leading whitespace, but float.parse doesn't accept it.
  if (isspace(*from_ptr)) OTHER_ERROR;
  bool needs_free = false;
  char* copied;
  if (!is_string(_raw_input) || to != input.length()) {  // Strings are null-terminated.
    // There is no way to tell strtod to stop early.
    // We have to copy the area we are interested in.
    copied = reinterpret_cast<char*>(malloc(to - from + 1));
    if (copied == null) ALLOCATION_FAILED;
    memcpy(copied, from_ptr, to - from);
    copied[to - from] = 0;
    from_ptr = copied;
    needs_free = true;
  }
  char* ptr = null;
  double result = strtod(from_ptr, &ptr);
  // Throw exception if conversion failed or strtod did not process the entire string.
  bool succeeded = *ptr == '\0';
  if (needs_free) free(copied);
  if (!succeeded) OTHER_ERROR;
  return Primitive::allocate_double(result, process);
}

PRIMITIVE(number_to_float) {
  ARGS(to_double, value);
  return Primitive::allocate_double(value, process);
}

PRIMITIVE(float_to_raw) {
  ARGS(double, receiver)
  auto raw = bit_cast<int64>(receiver);
  return Primitive::integer(raw, process);
}

PRIMITIVE(raw_to_float) {
  ARGS(int64, raw)
  double value = bit_cast<double>(raw);
  return Primitive::allocate_double(value, process);
}

PRIMITIVE(float_to_raw32) {
  ARGS(double, receiver)
  auto raw = bit_cast<uint32>(static_cast<float>(receiver));
  return Primitive::integer(raw, process);
}

PRIMITIVE(raw32_to_float) {
  ARGS(int64, raw)
  if ((static_cast<uint64>(raw) >> 32) != 0) OUT_OF_RANGE;
  double value = bit_cast<float>(static_cast<uint32>(raw));
  return Primitive::allocate_double(value, process);
}

PRIMITIVE(time) {
  return Primitive::integer(OS::get_monotonic_time(), process);
}

#ifdef TOIT_WINDOWS
static struct tm* gmtime_r(const time_t* t, struct tm* timeinfo) {
  return gmtime_s(timeinfo, t) ? NULL : timeinfo;
}

static struct tm* localtime_r(const time_t* t, struct tm* timeinfo) {
  return localtime_s(timeinfo, t) ? NULL : timeinfo;
}
#endif

PRIMITIVE(time_info) {
  ARGS(int64, timestamp, bool, is_utc)
  time_t t = timestamp;
  Array* result = process->object_heap()->allocate_array(9, Smi::zero());
  if (result == null) ALLOCATION_FAILED;
  struct tm timeinfo;
  if (is_utc) {
    gmtime_r(&t, &timeinfo);
  } else {
    localtime_r(&t, &timeinfo);
  }
  result->at_put(0, Smi::from(timeinfo.tm_sec));
  result->at_put(1, Smi::from(timeinfo.tm_min));
  result->at_put(2, Smi::from(timeinfo.tm_hour));
  result->at_put(3, Smi::from(timeinfo.tm_mday));
  result->at_put(4, Smi::from(timeinfo.tm_mon));
  result->at_put(5, Smi::from(timeinfo.tm_year + 1900));
  result->at_put(6, Smi::from(timeinfo.tm_wday));
  result->at_put(7, Smi::from(timeinfo.tm_yday));
  // When the information isn't available we just say false for daylight saving.
  result->at_put(8, BOOL(timeinfo.tm_isdst == 1));
  return result;
}

PRIMITIVE(seconds_since_epoch_local) {
  ARGS(int32, year, int32, month, int32, day, int32, hour, int32, min, int32, sec, Object, daylight_saving_is_active)
  struct tm decomposed;
  memset(&decomposed, 0, sizeof(decomposed));
  decomposed.tm_year = year - 1900;
  decomposed.tm_mon = month;
  decomposed.tm_mday = day;
  decomposed.tm_hour = hour;
  decomposed.tm_min = min;
  decomposed.tm_sec = sec;
  if (daylight_saving_is_active == process->program()->null_object()) {
    decomposed.tm_isdst = -1;
  } else if (daylight_saving_is_active == process->program()->true_object()) {
    decomposed.tm_isdst = 1;
  } else if (daylight_saving_is_active == process->program()->false_object()) {
    decomposed.tm_isdst = 0;
  } else {
    WRONG_TYPE;
  }
  errno = 0;
  int64 result = mktime(&decomposed);
  if (result == -1 && errno != 0) {
    return process->program()->null_object();
  }
  return Primitive::integer(result, process);
}

static char* current_buffer = null;

PRIMITIVE(set_tz) {
  ARGS(cstring, rules)
  size_t length = rules ? strlen(rules) : 0;
  if (length == 0) {
    putenv((char*)("TZ"));
    tzset();
    free(current_buffer);
    current_buffer = null;
    return process->program()->null_object();
  }
  const char* prefix = "TZ=";
  const int prefix_size = strlen(prefix);
  int buffer_size = prefix_size + length + 1;
  char* tz_buffer = static_cast<char*>(malloc(buffer_size));
  if (tz_buffer == null) ALLOCATION_FAILED;
  strcpy(tz_buffer, prefix);
  memcpy(tz_buffer + prefix_size, rules, buffer_size - prefix_size);
  tz_buffer[buffer_size - 1] = '\0';
  putenv((char*)("TZ"));
  putenv(tz_buffer);
  tzset();
  free(current_buffer);
  current_buffer = tz_buffer;
  return process->program()->null_object();
}

PRIMITIVE(platform) {
  const char* platform_name = OS::get_platform();
  return process->allocate_string_or_error(platform_name, strlen(platform_name));
}

PRIMITIVE(bytes_allocated_delta) {
  return Primitive::integer(process->bytes_allocated_delta(), process);
}

PRIMITIVE(process_stats) {
  ARGS(Object, list_object, int, group, int, id);
  Array* result = get_array_from_list(list_object, process);
  if (result == null) INVALID_ARGUMENT;
  if (group == -1 || id == -1) {
    if (group != -1 || id != -1) INVALID_ARGUMENT;
    group = process->group()->id();
    id = process->id();
  }
  Object* returned = VM::current()->scheduler()->process_stats(result, group, id, process);
  // Don't return the array - return the list that contains it.
  if (result == returned) return list_object;
  // Probably null or an exception.
  return returned;
}

PRIMITIVE(random) {
  return Smi::from(process->random() & 0xfffffff);
}

PRIMITIVE(random_seed) {
  ARGS(Blob, seed);
  process->random_seed(seed.address(), seed.length());
  return process->program()->null_object();
}

PRIMITIVE(add_entropy) {
  PRIVILEGED;
  ARGS(Blob, data);
  EntropyMixer::instance()->add_entropy(data.address(), data.length());
  return process->program()->null_object();
}

PRIMITIVE(count_leading_zeros) {
  ARGS(int64, v);
  return Smi::from(Utils::clz(v));
}

PRIMITIVE(popcount) {
  ARGS(int64, v);
  return Smi::from(Utils::popcount(v));
}

PRIMITIVE(string_length) {
  ARGS(StringOrSlice, receiver);
  return Smi::from(receiver.length());
}

PRIMITIVE(string_hash_code) {
  ARGS(String, receiver);
  return Smi::from(receiver->hash_code());
}

PRIMITIVE(blob_hash_code) {
  ARGS(Blob, receiver);
  auto hash = String::compute_hash_code_for(reinterpret_cast<const char*>(receiver.address()),
                                            receiver.length());
  return Smi::from(hash);
}

PRIMITIVE(hash_simple_json_string) {
  ARGS(Blob, bytes, int, offset);
  if (offset < 0) INVALID_ARGUMENT;
  for (word i = offset; i < bytes.length(); i++) {
    uint8 c = bytes.address()[i];
    if (c == '\\') return Smi::from(-1);
    if (c == '"') {
      auto hash = String::compute_hash_code_for(reinterpret_cast<const char*>(bytes.address() + offset),
                                                i - offset);
      return Smi::from(hash);
    }
  }
  return Smi::from(-1);
}

PRIMITIVE(json_skip_whitespace) {
  ARGS(Blob, bytes, int, offset);
  if (offset < 0) INVALID_ARGUMENT;
  word i = offset;
  for ( ; i < bytes.length(); i++) {
    uint8 c = bytes.address()[i];
    if (c != ' ' && c != '\n' && c != '\t' && c != '\r') return Smi::from(i);
  }
  return Smi::from(i);
}

PRIMITIVE(compare_simple_json_string) {
  ARGS(Blob, bytes, int, offset, StringOrSlice, string);
  if (offset < 0) INVALID_ARGUMENT;
  if (string.length() >= bytes.length() - offset) {
    return BOOL(false);
  }
  const uint8* start = bytes.address() + offset;
  if (memchr(start, '"', bytes.length() - offset) != start + string.length()) {
    return BOOL(false);
  }
  return BOOL(memcmp(string.address(), start, string.length()) == 0);
}

PRIMITIVE(size_of_json_number) {
  ARGS(Blob, bytes, int, offset);
  if (offset < 0 || offset >= bytes.length() - 1) INVALID_ARGUMENT;
  int is_float = 0;
  const uint8_t* p = bytes.address() + offset;
  const uint8_t* end = bytes.address() + bytes.length();
  for ( ; p < end; p++) {
    uint8 c = *p;
    //                                                               {[
    // The only characters that can legally terminate a JSON number are:
    // character  Hex   Hex & 0x1f
    // \t         09       09
    // \n         0a       0a
    // \r         0d       0d
    // space      20       00
    // ,          2c       0c
    // ]          5d       1d
    // }          7d       1d
    //
    // The only characters that can legally continue a JSON number are:
    // +          2b       0b
    // -          2d       0d
    // .          2e       0e
    // 0-9        30-39    10-19
    // E          45       05
    // e          65       05
    //
    // Apart from '\r' (carriage-return) and '-' (minus), there are no 5 bit
    // numbers that are on both sides in column 3, therefore a single 32 bit
    // bitmap serves to distinguish between characters that can be part of the
    // string and those that cannot.
    // The int.parse and float.parse routines will catch any syntax
    // errors that occur.                                         [
    // 0b0000_0011_1111_1111_0110_1000_0010_0000
    //          98 7654 3210  .-  +      E
    //     ]                    ,  nt          ␣
    static const uint32 NUMBER_TABLE = 0x3ff6820u;
    // A Floating point number must contain one of [.Ee].
    static const uint32 FLOAT_TABLE =     0x4020u;
    // Note that the `& 0x1f` operation is done for free by the machine
    // instruction.
    if (((NUMBER_TABLE >> (c & 0x1f)) & 1) == 0) break;
    if (c == '\r') break;  // Rarely the case.
    is_float |= (FLOAT_TABLE >> (c & 0x1f)) & 1;
  }
  word result = p - bytes.address();
  return Smi::from(is_float ? -result : result);
}

// The Toit code has already checked whether the types match, so we are not
// comparing strings with byte arrays.
PRIMITIVE(blob_equals) {
  ARGS(Object, receiver, Object, other)
  if (is_string(receiver) && is_string(other)) {
    // We can make use of hash code here.
    return BOOL(String::cast(receiver)->equals(other));
  }
  Blob receiver_blob;
  Blob other_blob;
  if (!receiver->byte_content(process->program(), &receiver_blob, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
  if (!other->byte_content(process->program(), &other_blob, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
  if (receiver_blob.length() != other_blob.length()) return BOOL(false);
  return BOOL(memcmp(receiver_blob.address(), other_blob.address(), receiver_blob.length()) == 0);
}

PRIMITIVE(string_compare) {
  ARGS(Object, receiver, Object, other)
  if (receiver == other) return Smi::from(0);
  Blob receiver_blob;
  Blob other_blob;
  if (!receiver->byte_content(process->program(), &receiver_blob, STRINGS_ONLY)) WRONG_TYPE;
  if (!other->byte_content(process->program(), &other_blob, STRINGS_ONLY)) WRONG_TYPE;
  return Smi::from(String::compare(receiver_blob.address(), receiver_blob.length(),
                                   other_blob.address(), other_blob.length()));
}

PRIMITIVE(string_rune_count) {
  ARGS(Blob, bytes)
  word count = 0;
  const uword WORD_MASK = WORD_SIZE - 1;
  const uint8* address = bytes.address();
  int len = bytes.length();
  // This algorithm counts the runes in word-sized chunks of UTF-8.
  // We have to ensure that the memory reads are word aligned to avoid memory
  // faults.
  // The first mask will make sure we skip over the bytes we don't need.
  int skipped_start_bytes = reinterpret_cast<uword>(address) & WORD_MASK;
  address -= skipped_start_bytes;  // Align the address
  len += skipped_start_bytes;

#ifdef BUILD_64
  const uword HIGH_BITS_IN_BYTES = 0x8080808080808080LL;
#else
  const uword HIGH_BITS_IN_BYTES = 0x80808080;
#endif

  // Create a mask that skips the first bytes we shouldn't count.
  // This code assumes a little-endian architecture.
  uword mask = HIGH_BITS_IN_BYTES << (skipped_start_bytes * BYTE_BIT_SIZE);

  // Iterate over all word-sized chunks. The mask is updated at the end of the
  // loop to count the full word-sized chunks of the next iteration.
  for (word i = 0; i < len; i += WORD_SIZE) {
    uword w = *reinterpret_cast<const uword*>(address + i);
    // The high bit in each byte of w should reflect whether we have an ASCII
    // character or the first byte of a multi-byte sequence.
    // w & (w << 1) captures the 11 prefix in the high bits of the first
    // byte of a multibyte sequence.
    // ~w captures the 0 in the high bit of an ASCII (single-byte) character.
    w = (w & (w << 1)) | ~w;
    // The mask removes the other bits, leaving the high bit in each byte.  It
    // also trims data from before the start of the string in the initial
    // position, which is handled first.
    w &= mask;
#ifdef BUILD_64
    count += Utils::popcount(w);
#else
    // Count the 1's in w, which can only be at the bit positions 7, 15, 23,
    // and 31.  We could use popcount, but ESP32 does not have an instruction
    // for that so we can do better, knowing that there are only 4 positions
    // that can be 1.
    w += w >> 16;
    // Now we have a 2-bit count at bit positions 7-8 and 15-16.
    count += ((w >> 7) + (w >> 15)) & 7;
#endif
    // After the first position we look at all bytes in the other positions.
    mask = HIGH_BITS_IN_BYTES;
  }

  if ((len & WORD_MASK) != 0) {
    // We counted too many bytes in the last chunk. Count the extra runes we
    // caught this way and remove it from the total.
    uword last_chunk = *reinterpret_cast<const uword*>(address + (len & ~WORD_MASK));
    int last_chunk_bytes = len & WORD_MASK;
    // Skip the the 'last_chunk_bytes' as they should be counted, but keep the
    // mask for the remaining ones.
    uword end_mask = HIGH_BITS_IN_BYTES << (last_chunk_bytes * BYTE_BIT_SIZE);
    uword w = last_chunk;
    w = (w & (w << 1)) | ~w;
    // Remove them from the total count.
    count -= Utils::popcount(w & end_mask);
  }

  return Primitive::integer(count, process);
}

PRIMITIVE(smi_to_string_base_10) {
  ARGS(word, receiver);
  char buffer[32];
  snprintf(buffer, sizeof(buffer), "%zd", receiver);
  return process->allocate_string_or_error(buffer);
}

// Used for %-based interpolation.  Only understands bases 8 and 16.
// Treats the input as an unsigned 64 integer like printf for those
// bases.
PRIMITIVE(printf_style_int64_to_string) {
  ARGS(int64, receiver, int, base);
  if (base != 2 && base != 8 && base != 16) INVALID_ARGUMENT;
  return printf_style_integer_to_string(process, receiver, base);
}

// Safe way to ensure a double print without chopping off characters.
static char* safe_double_print(const char* format, int precision, double value) {
  int size = 16;
  char* buffer = unvoid_cast<char*>(malloc(size));
  if (buffer == null) return null;
  while (true) {
    int required = snprintf(buffer, size, format, precision, value);
    // snprintf returns either -1 if the output was truncated or the number of chars
    // needed to store the result.
    if (required > -1 && required < size) {
      if (!isfinite(value)) return buffer;

      // Make sure the output looks like a double. It must have `e` or `.` in it.
      for (int i = 0; i < required; i++) {
        char c = buffer[i];
        if (c == 'e' || c == 'E' || c == '.') return buffer;
      }
      // Add the `.0`.
      if (size < required + 3) {
        buffer = unvoid_cast<char*>(realloc(buffer, required + 3));
        if (buffer == null) return null;
      }
      buffer[required] = '.';
      buffer[required + 1] = '0';
      buffer[required + 2] = '\0';
      return buffer;
    }
    free(buffer);
    // +3 for the potential ".0" and '\0'.
    size = required < 0 ? size * 2 : required + 1 + 2;
    buffer = unvoid_cast<char*>(malloc(size));
    if (buffer == null) return null;
  }
}

PRIMITIVE(float_to_string) {
  ARGS(double, receiver, Object, precision);
  if (isnan(receiver)) return process->allocate_string_or_error("nan");
  const char* format;
  word prec = 20;
  if (precision == process->program()->null_object()) {
    format = "%.*lg";
  } else {
    format = "%.*lf";
    if (is_large_integer(precision)) OUT_OF_BOUNDS;
    if (!is_smi(precision)) WRONG_TYPE;
    prec = Smi::cast(precision)->value();
    if (prec < 0 || prec > 64) OUT_OF_BOUNDS;
  }
  char* buffer = safe_double_print(format, prec, receiver);
  if (buffer == null) MALLOC_FAILED;
  Object* result = process->allocate_string(buffer);
  free(buffer);
  if (result == null) ALLOCATION_FAILED;
  return result;
}

PRIMITIVE(float_sign) {
  ARGS(double, receiver);
  int result;
  if (isnan(receiver)) {
    result = 1;  // All NaNs are treated as being positive.
  } else if (signbit(receiver)) {
    result = -1;
  } else if (receiver == 0.0) {
    result = 0;
  } else {
    result = 1;
  }
  return Smi::from(result);
}

PRIMITIVE(float_is_nan) {
  ARGS(double, receiver);
  return BOOL(isnan(receiver));
}

PRIMITIVE(float_is_finite) {
  ARGS(double, receiver);
  return BOOL(isfinite(receiver));
}

PRIMITIVE(number_to_integer) {
  ARGS(Object, receiver);
  if (is_smi(receiver) || is_large_integer(receiver)) return receiver;
  if (is_double(receiver)) {
    double value = Double::cast(receiver)->value();
    if (isnan(value)) INVALID_ARGUMENT;
    if (value < (double) INT64_MIN || value > (double) INT64_MAX) OUT_OF_RANGE;
    return Primitive::integer((int64) value, process);
  }
  WRONG_TYPE;
}

PRIMITIVE(float_sqrt) {
  ARGS(double, receiver);
  return Primitive::allocate_double(sqrt(receiver), process);
}

PRIMITIVE(float_ceil) {
  ARGS(double, receiver);
  return Primitive::allocate_double(ceil(receiver), process);
}

PRIMITIVE(float_floor) {
  ARGS(double, receiver);
  return Primitive::allocate_double(floor(receiver), process);
}

PRIMITIVE(float_trunc) {
  ARGS(double, receiver);
  return Primitive::allocate_double(trunc(receiver), process);
}

static bool is_validated_string(Program* program, Object* object) {
  // The only objects that are known to have valid UTF-8 sequences are
  // strings and string-slices.
  if (is_string(object)) return true;
  if (!is_heap_object(object)) return false;
  auto heap_object = HeapObject::cast(object);
  return heap_object->class_id() == program->string_slice_class_id();
}

static String* concat_strings(Process* process,
                              const uint8* bytes_a, int len_a,
                              const uint8* bytes_b, int len_b) {
  String* result = process->allocate_string(len_a + len_b);
  if (result == null) return null;
  // Initialize object.
  String::Bytes bytes(result);
  bytes._initialize(0, bytes_a, 0, len_a);
  bytes._initialize(len_a, bytes_b, 0, len_b);
  return result;
}

PRIMITIVE(string_add) {
  ARGS(Object, receiver, Object, other);
  // The operator already checks that the objects are strings, but we want to
  // be really sure the primitive wasn't called in a different way. Otherwise
  // we can't be sure that the content only has valid strings.
  String* result;
  if (!is_validated_string(process->program(), receiver)) WRONG_TYPE;
  if (!is_validated_string(process->program(), other)) WRONG_TYPE;
  Blob receiver_blob;
  Blob other_blob;
  // These should always succeed, as the operator already checks the objects are strings.
  if (!receiver->byte_content(process->program(), &receiver_blob, STRINGS_ONLY)) WRONG_TYPE;
  if (!other->byte_content(process->program(), &other_blob, STRINGS_ONLY)) WRONG_TYPE;
  result = concat_strings(process,
                          receiver_blob.address(), receiver_blob.length(),
                          other_blob.address(), other_blob.length());
  if (result == null) ALLOCATION_FAILED;
  return result;
}

static inline bool utf_8_continuation_byte(int c) {
  return (c & 0xc0) == 0x80;
}

PRIMITIVE(string_slice) {
  ARGS(String, receiver, int, from, int, to);
  String::Bytes bytes(receiver);
  int length = bytes.length();
  if (from == 0 && to == length) return receiver;
  if (from < 0 || to > length || from > to) OUT_OF_BOUNDS;
  if (from != length) {
    int first = bytes.at(from);
    if (utf_8_continuation_byte(first)) ILLEGAL_UTF_8;
  }
  if (to == from) {
    // TODO: there should be a singleton empty string in the roots in program.h.
    return process->allocate_string_or_error("");
  }
  ASSERT(from < length);  // Checked above.
  // We must guard against chopped up UTF-8 sequences.  We can do this, knowing
  // that the receiver string is valid UTF-8, so a very minimal verification is
  // enough.
  if (to != length) {
    int first_after = bytes.at(to);
    if (utf_8_continuation_byte(first_after)) ILLEGAL_UTF_8;
  }
  ASSERT(from >= 0);
  ASSERT(to <= receiver->length());  // Checked above.
  ASSERT(from < to);
  int result_len = to - from;
  String* result = process->allocate_string(result_len);
  if (result == null) ALLOCATION_FAILED;
  // Initialize object.
  String::Bytes result_bytes(result);
  result_bytes._initialize(0, receiver, from, to - from);
  return result;
}

PRIMITIVE(concat_strings) {
  ARGS(Array, array);
  Program* program = process->program();
  // First make sure we have an array of strings.
  for (int index = 0; index < array->length(); index++) {
    if (!is_validated_string(process->program(), array->at(index))) WRONG_TYPE;
  }
  int length = 0;
  for (int index = 0; index < array->length(); index++) {
    Blob blob;
    HeapObject::cast(array->at(index))->byte_content(program, &blob, STRINGS_ONLY);
    length += blob.length();
  }
  String* result = process->allocate_string(length);
  if (result == null) ALLOCATION_FAILED;
  String::Bytes bytes(result);
  int pos = 0;
  for (int index = 0; index < array->length(); index++) {
    Blob blob;
    HeapObject::cast(array->at(index))->byte_content(program, &blob, STRINGS_ONLY);
    int len = blob.length();
    bytes._initialize(pos, blob.address(), 0, len);
    pos += len;
  }
  return result;
}

PRIMITIVE(string_at) {
  ARGS(StringOrSlice, receiver, int, index);
  if (index < 0 || index >= receiver.length()) OUT_OF_BOUNDS;
  int c = receiver.address()[index] & 0xff;
  if (c <= Utils::MAX_ASCII) return Smi::from(c);
  // Invalid index.  Return null.  This means you can still scan for ASCII characters very simply.
  if (!Utils::is_utf_8_prefix(c)) return process->program()->null_object();
  int n_byte_sequence = Utils::bytes_in_utf_8_sequence(c);
  // String contain only verified UTF-8 so there are some things we can guarantee.
  ASSERT(n_byte_sequence <= 4);
  ASSERT(index + n_byte_sequence <= receiver.length());
  c = Utils::payload_from_prefix(c);
  for (int j = 1; j < n_byte_sequence; j++) {
    c <<= Utils::UTF_8_BITS_PER_BYTE;
    c |= receiver.address()[index + j] & Utils::UTF_8_MASK;
  }
  ASSERT(c > Utils::MAX_ASCII);  // Verifier has prevented overlong sequences.
  return Smi::from(c);
}

PRIMITIVE(string_raw_at) {
  ARGS(StringOrSlice, receiver, int, index);
  if (index < 0 || index >= receiver.length()) OUT_OF_BOUNDS;
  int c = receiver.address()[index] & 0xff;
  return Smi::from(c);
}

PRIMITIVE(array_length) {
  ARGS(Array, receiver);
  return Smi::from(receiver->length());
}

PRIMITIVE(array_at) {
  ARGS(Array, receiver, int, index);
  if (index >= 0 && index < receiver->length()) return receiver->at(index);
  OUT_OF_BOUNDS;
}

PRIMITIVE(array_at_put) {
  ARGS(Array, receiver, int, index, Object, value);
  if (index >= 0 && index < receiver->length()) {
    receiver->at_put(index, value);
    return value;
  }
  OUT_OF_BOUNDS;
}

// Allocates a new array and copies old_length elements from the old array into
// the new one.
PRIMITIVE(array_expand) {
  ARGS(Array, old, word, old_length, word, length);
  if (length == 0) return process->program()->empty_array();
  if (length < 0) OUT_OF_BOUNDS;
  if (length > Array::max_length_in_process()) OUT_OF_RANGE;
  if (old_length < 0 || old_length > old->length() || old_length > length) OUT_OF_RANGE;
  Object* result = process->object_heap()->allocate_array(length, Smi::from(0));
  if (result == null) ALLOCATION_FAILED;
  Array* new_array = Array::cast(result);
  new_array->copy_from(old, old_length);
  Object* filler = process->program()->null_object();
  new_array->fill(old_length, filler);
  return new_array;
}

// Memcpy betwen arrays.
PRIMITIVE(array_replace) {
  ARGS(Array, dest, word, index, Array, source, word, from, word, to);
  word dest_length = dest->length();
  word source_length = source->length();
  if (index < 0 || from < 0 || from > to || to > source_length) OUT_OF_BOUNDS;
  word len = to - from;
  if (index + len > dest_length) OUT_OF_BOUNDS;
  memmove(dest->content() + index * WORD_SIZE,
          source->content() + from * WORD_SIZE,
          len * WORD_SIZE);
  return process->program()->null_object();
}

PRIMITIVE(array_new) {
  ARGS(int, length, Object, filler);
  if (length == 0) return process->program()->empty_array();
  if (length < 0) OUT_OF_BOUNDS;
  if (length > Array::max_length_in_process()) OUT_OF_RANGE;
  return Primitive::allocate_array(length, filler, process);
}

PRIMITIVE(list_add) {
  ARGS(Object, receiver, Object, value);
  if (is_instance(receiver)) {
    Instance* list = Instance::cast(receiver);
    if (list->class_id() == process->program()->list_class_id()) {
      Object* array_object;
      if (is_array(array_object = list->at(0))) {
        // Small array backing case.
        Array* array = Array::cast(array_object);
        word size = Smi::cast(list->at(1))->value();
        if (size < array->length()) {
          list->at_put(1, Smi::from(size + 1));
          array->at_put(size, value);
          return process->program()->null_object();
        }
      } else {
        // Large array backing case.
        Object* size_object = list->at(1);
        if (is_smi(size_object)) {
          word size = Smi::cast(size_object)->value();
          if (Smi::is_valid(size + 1)) {
            if (Interpreter::fast_at(process, array_object, size_object, true, &value)) {
              list->at_put(1, Smi::from(size + 1));
              return process->program()->null_object();
            }
          }
        }
      }
    }
  }
  INVALID_ARGUMENT;  // Handled in Toit code.
}

PRIMITIVE(byte_array_is_raw_bytes) {
  ARGS(ByteArray, byte_array);
  bool result = (!byte_array->has_external_address()) || byte_array->external_tag() == RawByteTag;
  return BOOL(result);
}

PRIMITIVE(byte_array_length) {
  ARGS(ByteArray, receiver);
  if (!receiver->has_external_address() || receiver->external_tag() == RawByteTag || receiver->external_tag() == MappedFileTag) {
    return Smi::from(ByteArray::Bytes(receiver).length());
  }
  WRONG_TYPE;
}

PRIMITIVE(byte_array_at) {
  ARGS(ByteArray, receiver, int, index);
  if (!receiver->has_external_address() || receiver->external_tag() == RawByteTag || receiver->external_tag() == MappedFileTag) {
    ByteArray::Bytes bytes(receiver);
    if (!bytes.is_valid_index(index)) OUT_OF_BOUNDS;
    return Smi::from(bytes.at(index));
  }
  WRONG_TYPE;
}

PRIMITIVE(byte_array_at_put) {
  ARGS(ByteArray, receiver, int, index, int64, value);
  if (!receiver->has_external_address() || receiver->external_tag() == RawByteTag) {
    ByteArray::Bytes bytes(receiver);
    if (!bytes.is_valid_index(index)) OUT_OF_BOUNDS;
    bytes.at_put(index, (uint8) value);
    return Smi::from((uint8) value);
  }
  WRONG_TYPE;
}

PRIMITIVE(byte_array_new) {
  ARGS(int, length, int, filler);
  if (length < 0) OUT_OF_BOUNDS;
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) ALLOCATION_FAILED;
  if (filler != 0) {
    ByteArray::Bytes bytes(result);
    memset(bytes.address(), filler, length);
  }
  return result;
}

PRIMITIVE(byte_array_new_external) {
  ARGS(int, length);
  if (length < 0) OUT_OF_BOUNDS;
  bool force_external = true;
  ByteArray* result = process->allocate_byte_array(length, force_external);
  if (result == null) ALLOCATION_FAILED;
  return result;
}

PRIMITIVE(byte_array_replace) {
  ARGS(MutableBlob, receiver, int, index, Blob, source_object, int, from, int, to);
  if (index < 0 || from < 0 || to < 0 || to > source_object.length()) OUT_OF_BOUNDS;
  int length = to - from;
  if (length < 0 || index + length > receiver.length()) OUT_OF_BOUNDS;

  uint8* dest = receiver.address() + index;
  const uint8* source = source_object.address() + from;
  memmove(dest, source, length);
  return process->program()->null_object();
}

PRIMITIVE(smi_unary_minus) {
  ARGS(Object, receiver);
  if (!is_smi(receiver)) WRONG_TYPE;
  // We can't assume that `-x` is still a smi, as -MIN_SMI_VALUE > MAX_SMI_VALUE.
  // However, it must fit a `word` as smis are smaller than words.
  word value = Smi::cast(receiver)->value();
  return Primitive::integer(-value, process);
}

PRIMITIVE(smi_not) {
  ARGS(word, receiver);
  return Smi::from(~receiver);
}

PRIMITIVE(smi_and) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) return Smi::from(receiver & Smi::cast(arg)->value());
  if (!is_large_integer(arg)) WRONG_TYPE;
  return Primitive::integer(((int64) receiver) & LargeInteger::cast(arg)->value() , process);
}

PRIMITIVE(smi_or) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) return Smi::from(receiver | Smi::cast(arg)->value());
  if (!is_large_integer(arg)) WRONG_TYPE;
  return Primitive::integer(((int64) receiver) | LargeInteger::cast(arg)->value() , process);
}

PRIMITIVE(smi_xor) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) return Smi::from(receiver ^ Smi::cast(arg)->value());
  if (!is_large_integer(arg)) WRONG_TYPE;
  return Primitive::integer(((int64) receiver) ^ LargeInteger::cast(arg)->value() , process);
}

PRIMITIVE(smi_shift_right) {
  ARGS(word, receiver, int64, bits_to_shift);
  if (bits_to_shift < 0) NEGATIVE_ARGUMENT;
  if (bits_to_shift >= WORD_BIT_SIZE) return Smi::from(receiver < 0 ? -1 : 0);
  return Smi::from(receiver >> bits_to_shift);
}

PRIMITIVE(smi_unsigned_shift_right) {
  ARGS(Object, receiver, int64, bits_to_shift);
  if (!is_smi(receiver)) WRONG_TYPE;
  if (bits_to_shift < 0) NEGATIVE_ARGUMENT;
  if (bits_to_shift >= 64) return Smi::zero();
  uint64 value = static_cast<uint64>(Smi::cast(receiver)->value());
  int64 result = static_cast<int64>(value >> bits_to_shift);
  return Primitive::integer(result, process);
}

PRIMITIVE(smi_shift_left) {
  ARGS(Object, receiver, int64, number_of_bits);
  if (!is_smi(receiver)) WRONG_TYPE;
  if (number_of_bits < 0) NEGATIVE_ARGUMENT;
  if (number_of_bits >= 64) return Smi::zero();
  int64 value = Smi::cast(receiver)->value();
  return Primitive::integer(value << number_of_bits, process);
}

PRIMITIVE(task_new) {
  ARGS(Instance, code);
  Task* task = process->object_heap()->allocate_task();
  if (task == null) ALLOCATION_FAILED;
  Method entry = process->program()->entry_task();
  if (!entry.is_valid()) FATAL("Cannot locate task entry method");

  Object* tru = process->program()->true_object();
  if ((reinterpret_cast<uword>(tru) & 3) != 1) FATAL("Program heap misaligned");

  Task* old = process->object_heap()->task();
  process->scheduler_thread()->interpreter()->store_stack();

  process->object_heap()->set_task(task);
  process->scheduler_thread()->interpreter()->load_stack();
  process->scheduler_thread()->interpreter()->prepare_task(entry, code);
  process->scheduler_thread()->interpreter()->store_stack();

  process->object_heap()->set_task(old);
  process->scheduler_thread()->interpreter()->load_stack();

  return task;
}

PRIMITIVE(task_transfer) {
  ARGS(Task, to, bool, detach_stack);
  Task* from = process->object_heap()->task();
  if (from != to) {
    // Make sure we don't transfer to a dead task.
    if (!to->has_stack()) OTHER_ERROR;
    process->scheduler_thread()->interpreter()->store_stack();
    // Remove the link from the task to the stack if requested.
    if (detach_stack) from->detach_stack();
    process->object_heap()->set_task(to);
    process->scheduler_thread()->interpreter()->load_stack();
  }
  return Primitive::mark_as_error(to);
}

PRIMITIVE(process_send) {
  ARGS(int, process_id, int, type, Object, array);

  unsigned size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(array)) {
      return size_encoder.create_error_object(process);
    }
    size = size_encoder.size();
  }

  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  if (buffer == null) MALLOC_FAILED;

  MessageEncoder encoder(process, buffer);
  if (!encoder.encode(array)) {
    encoder.free_copied();
    free(buffer);
    return encoder.create_error_object(process);
  }

  SystemMessage* message = _new SystemMessage(type, process->group()->id(), process->id(), buffer);

  if (message == null) {
    encoder.free_copied();
    free(buffer);
    MALLOC_FAILED;
  }

  // From here on, the destructor of SystemMessage will free the buffer and
  // potentially the externals too if ownership isn't transferred elsewhere
  // when the message is received.
  scheduler_err_t result = (process_id >= 0)
      ? VM::current()->scheduler()->send_message(process_id, message)
      : VM::current()->scheduler()->send_system_message(message);
  if (result == MESSAGE_OK) {
    // Neuter will disassociate the external memory from the ByteArray, and
    // also remove the memory from the accounting of the sending process.  The
    // memory is unaccounted until it is attached to the receiving process.
    encoder.neuter_externals();
    // TODO(kasper): Consider doing in-place shrinking of internal, non-constant
    // byte arrays and strings.
    return process->program()->null_object();
  } else {
    // Sending failed. Free any copied bits, but make sure to not free the externals
    // that have not been neutered on this path.
    encoder.free_copied();
    message->free_data_but_keep_externals();
    delete message;
    // Object* result = process->allocate_string_or_error("MESSAGE_NO_SUCH_RECEIVER");
    // if (Primitive::is_error(result)) return result;
    // return Primitive::mark_as_error(HeapObject::cast(result));
    return process->program()->null_object();
  }
}

Object* MessageEncoder::create_error_object(Process* process) {
  Object* result = null;
  if (malloc_failed_) {
    MALLOC_FAILED;
  } else if (nesting_too_deep_) {
    result = process->allocate_string_or_error("NESTING_TOO_DEEP");
  } else if (problematic_class_id_ >= 0) {
    result = Primitive::allocate_array(1, Smi::from(problematic_class_id_), process);
  } else if (too_many_externals_) {
    result = process->allocate_string_or_error("TOO_MANY_EXTERNALS");
  }
  if (result) {
    if (Primitive::is_error(result)) return result;
    return Primitive::mark_as_error(HeapObject::cast(result));
  }
  // The remaining errors are things like unserializable non-instances, non-smi
  // lengths, large lists.  TODO: Be more specific and/or remove some limitations.
  WRONG_TYPE;
}

PRIMITIVE(task_has_messages) {
  if (process->object_heap()->has_finalizer_to_run()) {
    return BOOL(true);
  }
  Message* message = process->peek_message();
  return BOOL(message != null);
}

PRIMITIVE(task_receive_message) {
  ObjectHeap* heap = process->object_heap();
  if (heap->has_finalizer_to_run()) {
    return heap->next_finalizer_to_run();
  }

  Message* message = process->peek_message();
  MessageType message_type = message->message_type();
  Object* result = process->program()->null_object();

  if (message_type == MESSAGE_MONITOR_NOTIFY) {
    ObjectNotifyMessage* object_notify = static_cast<ObjectNotifyMessage*>(message);
    ObjectNotifier* notifier = object_notify->object_notifier();
    if (notifier != null) result = notifier->object();
  } else if (message_type == MESSAGE_SYSTEM) {
    Array* array = process->object_heap()->allocate_array(4, Smi::from(0));
    if (array == null) ALLOCATION_FAILED;
    SystemMessage* system = static_cast<SystemMessage*>(message);
    MessageDecoder decoder(process, system->data());

    Object* decoded = decoder.decode();
    if (decoder.allocation_failed()) {
      decoder.remove_disposing_finalizers();
      ALLOCATION_FAILED;
    }
    decoder.register_external_allocations();
    system->free_data_but_keep_externals();

    array->at_put(0, Smi::from(system->type()));
    array->at_put(1, Smi::from(system->gid()));
    array->at_put(2, Smi::from(system->pid()));
    array->at_put(3, decoded);
    result = array;
  } else {
    UNREACHABLE();
  }

  process->remove_first_message();
  return result;
}

PRIMITIVE(add_finalizer) {
  ARGS(HeapObject, object, Object, finalizer)
  if (process->has_finalizer(object, finalizer)) OUT_OF_BOUNDS;
  if (!process->add_finalizer(object, finalizer)) MALLOC_FAILED;
  return object;
}

PRIMITIVE(remove_finalizer) {
  ARGS(HeapObject, object)
  return BOOL(process->remove_finalizer(object));
}

PRIMITIVE(gc_count) {
  return Smi::from(process->object_heap()->gc_count(NEW_SPACE_GC));
}

PRIMITIVE(create_off_heap_byte_array) {
  ARGS(int, length);
  if (length < 0) NEGATIVE_ARGUMENT;

  AllocationManager allocation(process);
  uint8* buffer = allocation.alloc(length);
  if (buffer == null) ALLOCATION_FAILED;

  ByteArray* result = process->object_heap()->allocate_proxy(length, buffer, true);
  if (result == null) ALLOCATION_FAILED;
  allocation.keep_result();
  return result;
}

PRIMITIVE(vm_sdk_version) {
  return process->allocate_string_or_error(vm_git_version());
}

PRIMITIVE(vm_sdk_info) {
  return process->allocate_string_or_error(vm_git_info());
}

PRIMITIVE(vm_sdk_model) {
  return process->allocate_string_or_error(vm_sdk_model());
}

PRIMITIVE(app_sdk_version) {
  return process->program()->app_sdk_version();
}

PRIMITIVE(app_sdk_info) {
  return process->program()->app_sdk_info();
}

PRIMITIVE(encode_object) {
  ARGS(Object, target);
  MallocedBuffer buffer(1024);
  ProgramOrientedEncoder encoder(process->program(), &buffer);
  bool success = encoder.encode(target);
  if (!success) OUT_OF_BOUNDS;
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

#ifdef IOT_DEVICE
#define STACK_ENCODING_BUFFER_SIZE (2*1024)
#else
#define STACK_ENCODING_BUFFER_SIZE (16*1024)
#endif

PRIMITIVE(encode_error) {
  ARGS(Object, type, Object, message);
  MallocedBuffer buffer(STACK_ENCODING_BUFFER_SIZE);
  if (!buffer.has_content()) MALLOC_FAILED;
  ProgramOrientedEncoder encoder(process->program(), &buffer);
  process->scheduler_thread()->interpreter()->store_stack();
  bool success = encoder.encode_error(type, message, process->task()->stack());
  process->scheduler_thread()->interpreter()->load_stack();
  if (!success) OUT_OF_BOUNDS;
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

PRIMITIVE(rebuild_hash_index) {
  ARGS(Object, o, Object, n);
  // Sometimes the array is too big, and is a large array.  In this case, use
  // the Toit implementation.
  if (!is_array(o) || !is_array(n)) OUT_OF_RANGE;
  Array* old_array = Array::cast(o);
  Array* new_array = Array::cast(n);
  word index_mask = new_array->length() - 1;
  word length = old_array->length();
  for (word i = 0; i < length; i++) {
    Object* o = old_array->at(i);
    word hash_and_position;
    if (is_smi(o)) {
      hash_and_position = Smi::cast(o)->value();
    } else if (is_large_integer(o)) {
      hash_and_position = LargeInteger::cast(o)->value();
    } else {
      INVALID_ARGUMENT;
    }
    word slot = hash_and_position & index_mask;
    word step = 1;
    while (new_array->at(slot) != 0) {
      slot = (slot + step) & index_mask;
      step++;
    }
    new_array->at_put(slot, Smi::from(hash_and_position));
  }

  return process->program()->null_object();
}

PRIMITIVE(profiler_install) {
  ARGS(bool, profile_all_tasks);
  if (process->profiler() != null) ALREADY_EXISTS;
  int result = process->install_profiler(profile_all_tasks ? -1 : process->task()->id());
  if (result == -1) MALLOC_FAILED;
  return Smi::from(result);
}

PRIMITIVE(profiler_start) {
  Profiler* profiler = process->profiler();
  if (profiler == null) ALREADY_CLOSED;
  if (profiler->is_active()) return process->program()->false_object();
  profiler->start();
  // Tell the scheduler that a new process has an active profiler.
  VM::current()->scheduler()->activate_profiler(process);
  return process->program()->true_object();
}

PRIMITIVE(profiler_stop) {
  Profiler* profiler = process->profiler();
  if (profiler == null) ALREADY_CLOSED;
  if (!profiler->is_active()) return process->program()->false_object();
  profiler->stop();
  // Tell the scheduler to deactivate profiling for the process.
  VM::current()->scheduler()->deactivate_profiler(process);
  return process->program()->true_object();
}

PRIMITIVE(profiler_encode) {
  ARGS(String, title, int, cutoff);
  Profiler* profiler = process->profiler();
  if (profiler == null) ALREADY_CLOSED;
  MallocedBuffer buffer(4096);
  ProgramOrientedEncoder encoder(process->program(), &buffer);
  bool success = encoder.encode_profile(profiler, title, cutoff);
  if (!success) OUT_OF_BOUNDS;
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

PRIMITIVE(profiler_uninstall) {
  Profiler* profiler = process->profiler();
  if (profiler == null) ALREADY_CLOSED;
  process->uninstall_profiler();
  return process->program()->null_object();
}

PRIMITIVE(set_max_heap_size) {
  ARGS(word, max_bytes);
  process->set_max_heap_size(max_bytes);
  process->object_heap()->update_pending_limit();
  return process->program()->null_object();
}

PRIMITIVE(get_real_time_clock) {
  Array* result = process->object_heap()->allocate_array(2, Smi::zero());
  if (result == null) ALLOCATION_FAILED;

  struct timespec time{};
  if (!OS::get_real_time(&time)) OTHER_ERROR;

  Object* tv_sec = Primitive::integer(time.tv_sec, process);
  if (Primitive::is_error(tv_sec)) return tv_sec;
  Object* tv_nsec = Primitive::integer(time.tv_nsec, process);
  if (Primitive::is_error(tv_sec)) return tv_nsec;
  result->at_put(0, tv_sec);
  result->at_put(1, tv_nsec);
  return result;
}

PRIMITIVE(set_real_time_clock) {
#ifdef TOIT_FREERTOS
  ARGS(int64, tv_sec, int64, tv_nsec);
  if (tv_sec < LONG_MIN || tv_sec > LONG_MAX) INVALID_ARGUMENT;
  if (tv_nsec < LONG_MIN || tv_nsec > LONG_MAX) INVALID_ARGUMENT;
  struct timespec time = {
    .tv_sec = static_cast<long>(tv_sec),
    .tv_nsec = static_cast<long>(tv_nsec),
  };
  static_assert(sizeof(time.tv_sec) == sizeof(long), "Unexpected size of timespec field");
  static_assert(sizeof(time.tv_nsec) == sizeof(long), "Unexpected size of timespec field");
  if (!OS::set_real_time(&time)) OTHER_ERROR;
#endif
  return Smi::zero();
}

PRIMITIVE(get_system_time) {
  return Primitive::integer(OS::get_system_time(), process);
}

PRIMITIVE(debug_set_memory_limit) {
  PRIVILEGED;
  ARGS(int64, limit);
#ifdef TOIT_POSIX
  struct rlimit limits;
  int result = getrlimit(RLIMIT_DATA, &limits);
  if (result != 0) {
    return Primitive::os_error(errno, process);
  }
  limits.rlim_cur = limit;
  result = setrlimit(RLIMIT_DATA, &limits);
  if (result != 0) {
    return Primitive::os_error(errno, process);
  }
  return process->program()->true_object();
#else
  USE(limit);
  return process->program()->false_object();
#endif
}

#ifdef TOIT_CMPCTMALLOC

class ByteArrayHeapFragmentationDumper : public HeapFragmentationDumper {
 public:
  ByteArrayHeapFragmentationDumper(const char* description, uint8* string, uword size)
    : HeapFragmentationDumper(description, string),
      string_(string),
      size_(size),
      position_(0) {
    write_start();
  }

  virtual void write_buffer(const uint8* str, uword len) {
    // We don't care about this but it helps debug the
    // FlashHeapFragmentationDumper which has this requirement.
    ASSERT(len % 16 == 0);
    if (position_ + len > size_) {
      set_overflow();
      return;
    }
    memcpy(string_ + position_, str, len);
    position_ += len;
  }

  uword position() { return position_; }

 private:
  uint8* string_;
  uword size_;
  uword position_;
};

#if defined(TOIT_LINUX) || defined (TOIT_FREERTOS)
// Moved into its own function because the FragmentationDumper is a large
// object that will increase the stack size if it is inlined.
static __attribute__((noinline)) uword get_heap_dump_size(const char* description) {
  SizeDiscoveryFragmentationDumper size_discovery(description);
  int flags = ITERATE_ALL_ALLOCATIONS | ITERATE_UNALLOCATED;
  int caps = OS::toit_heap_caps_flags_for_heap();
  heap_caps_iterate_tagged_memory_areas(&size_discovery, null, HeapFragmentationDumper::log_allocation, flags, caps);
  size_discovery.write_end();

  return size_discovery.size();
}

static __attribute__((noinline)) word heap_dump_to_byte_array(const char* reason, uint8* contents, uword size) {
  ByteArrayHeapFragmentationDumper dumper(reason, contents, size);
  int flags = ITERATE_ALL_ALLOCATIONS | ITERATE_UNALLOCATED;
  int caps = OS::toit_heap_caps_flags_for_heap();
  heap_caps_iterate_tagged_memory_areas(&dumper, null, HeapFragmentationDumper::log_allocation, flags, caps);
  dumper.write_end();
  if (dumper.has_overflow()) return -1;
  return dumper.position();
}
#endif

#endif // def TOIT_CMPCTMALLOC

PRIMITIVE(dump_heap) {
#ifndef TOIT_CMPCTMALLOC
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(int, padding);
  if (padding < 0 || padding > 0x10000) OUT_OF_RANGE;
#if defined(TOIT_LINUX)
  if (heap_caps_iterate_tagged_memory_areas == null) {
    // This always happens on the server unless we are running with
    // cmpctmalloc (using LD_PRELOAD), which supports iterating the heap in
    // this way.
    return process->program()->null_object();
  }
#endif

#if defined(TOIT_LINUX) || defined (TOIT_FREERTOS)
  const char* description = "Heap usage report";

  uword size = get_heap_dump_size(description);

  ByteArray* result = process->allocate_byte_array(size + padding);
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  uint8* contents = bytes.address();

  word actual_size = heap_dump_to_byte_array(description, contents, size + padding);
  if (actual_size < 0) {
    // Due to other threads allocating and freeing we may not succeed in creating
    // a heap layout dump, in which case we return null.
    return process->program()->null_object();
  }

  // Fill up with ubjson no-ops.
  memset(contents + actual_size, 'N', size + padding - actual_size);

  return result;
#else
  return process->program()->null_object();
#endif

#endif // def TOIT_CMPCTMALLOC
}

PRIMITIVE(serial_print_heap_report) {
#ifdef TOIT_CMPCTMALLOC
  ARGS(cstring, marker, int, max_pages);
  OS::heap_summary_report(max_pages, marker);
#endif // def TOIT_CMPCTMALLOC
  return process->program()->null_object();
}

PRIMITIVE(get_env) {
#if defined (TOIT_FREERTOS)
  // FreeRTOS supports environment variables, but we prefer not to expose them.
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(cstring, key);
  // TODO(florian): getenv is not reentrant.
  //   We should have a lock around `getenv` and `setenv`.
  const char* result = OS::getenv(key);
  if (result == null) return process->program()->null_object();
  return process->allocate_string_or_error(result, strlen(result));
#endif
}

PRIMITIVE(literal_index) {
  ARGS(Object, o);
  auto null_object = process->program()->null_object();
  if (!is_heap_object(o)) return null_object;
  auto& literals = process->program()->literals;
  for (int i = 0; i < literals.length(); i++) {
    if (literals.at(i) == o) return Smi::from(i);
  }
  return null_object;
}

PRIMITIVE(word_size) {
  return Smi::from(WORD_SIZE);
}

#ifdef TOIT_FREERTOS
static spi_flash_mmap_handle_t firmware_mmap_handle;
static bool firmware_is_mapped = false;
#endif

PRIMITIVE(firmware_map) {
  ARGS(Object, bytes);
#ifndef TOIT_FREERTOS
  return bytes;
#else
  if (bytes != process->program()->null_object()) {
    // If we're passed non-null bytes, we use that as the
    // firmware bits.
    return bytes;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (firmware_is_mapped) {
    // We unmap to allow the next attempt to get the current
    // system image to succeed.
    spi_flash_munmap(firmware_mmap_handle);
    firmware_is_mapped = false;
    QUOTA_EXCEEDED;  // Quota is 1.
  }

  const esp_partition_t* current_partition = esp_ota_get_running_partition();
  if (current_partition == null) OTHER_ERROR;

  const void* mapped_to = null;
  esp_err_t err = esp_partition_mmap(
      current_partition,
      0,  // Offset from start of partition.
      current_partition->size,
      SPI_FLASH_MMAP_INST,
      &mapped_to,
      &firmware_mmap_handle);
  if (err != ESP_OK) OTHER_ERROR;

  firmware_is_mapped = true;
  proxy->set_external_address(
      current_partition->size,
      const_cast<uint8*>(reinterpret_cast<const uint8*>(mapped_to)));
  return proxy;
#endif
}

PRIMITIVE(firmware_unmap) {
#ifdef TOIT_FREERTOS
  ARGS(ByteArray, proxy);
  if (!firmware_is_mapped) process->program()->null_object();
  spi_flash_munmap(firmware_mmap_handle);
  firmware_is_mapped = false;
  proxy->clear_external_address();
#endif
  return process->program()->null_object();
}

PRIMITIVE(firmware_mapping_at) {
  ARGS(Instance, receiver, int, index);
  int offset = Smi::cast(receiver->at(1))->value();
  int size = Smi::cast(receiver->at(2))->value();
  if (index < 0 || index >= size) OUT_OF_BOUNDS;

  Blob input;
  if (!receiver->at(0)->byte_content(process->program(), &input, STRINGS_OR_BYTE_ARRAYS)) {
    WRONG_TYPE;
  }

  // Firmware is potentially mapped into memory that only allow word
  // access. We read the full word before masking and shifting. This
  // asssumes that we're running on a little endian platform.
  index += offset;
  const uint32* words = reinterpret_cast<const uint32*>(input.address());
  uint32 shifted = words[index >> 2] >> ((index & 3) << 3);
  return Smi::from(shifted & 0xff);
}

PRIMITIVE(firmware_mapping_copy) {
  ARGS(Instance, receiver, int, from, int, to, ByteArray, into, int, index);
  int offset = Smi::cast(receiver->at(1))->value();
  int size = Smi::cast(receiver->at(2))->value();
  if (!Utils::is_aligned(from + offset, sizeof(uint32)) ||
      !Utils::is_aligned(to + offset, sizeof(uint32))) INVALID_ARGUMENT;
  if (from > to || from < 0 || to > size) OUT_OF_BOUNDS;

  Blob input;
  if (!receiver->at(0)->byte_content(process->program(), &input, STRINGS_OR_BYTE_ARRAYS)) {
    WRONG_TYPE;
  }

  // Firmware is potentially mapped into memory that only allow word
  // access. We use an IRAM safe memcpy alternative that guarantees
  // always reading whole words to avoid issues with this.
  ByteArray::Bytes output(into);
  int bytes = to - from;
  iram_safe_memcpy(output.address() + index, input.address() + from + offset, bytes);
  return Smi::from(index + bytes);
}

} // namespace toit

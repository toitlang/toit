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

#ifdef TOIT_ESP32
#include "spi_flash_mmap.h"
#include "rtc_memory_esp32.h"
#endif

#ifndef RAW
#include "compiler/compiler.h"
#endif

#include <math.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <cinttypes>
#include <ctype.h>
#include <errno.h>
#include <sys/time.h>

#ifdef TOIT_FREERTOS
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#endif

#ifdef TOIT_WINDOWS
#include <windows.h>
#endif

#ifdef TOIT_ESP32
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#elif defined(TOIT_POSIX)
#include <sys/resource.h>
#endif

#ifdef __x86_64__
#include <emmintrin.h>  // SSE2 primitives.
typedef __m128i uint128_t;
#endif

namespace toit {

MODULE_IMPLEMENTATION(core, MODULE_CORE)

#if defined(TOIT_WINDOWS)
static Object* write_on_std(const uint8_t* bytes, size_t length, bool is_stdout, bool newline, Process* process) {
  HANDLE console = GetStdHandle(is_stdout ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
  if (console == INVALID_HANDLE_VALUE) {
    return Primitive::os_error(GetLastError(), process);
  }

  DWORD written;
  DWORD mode;

  // Check if the handle is a console handle.
  if (GetConsoleMode(console, &mode)) {
    // Write to the console.
    WriteConsoleA(console, bytes, (DWORD)length, &written, NULL);

    if (newline) {
      WriteConsoleA(console, "\r\n", 2, &written, NULL);
    }
  } else {
    // Handle redirection case.
    WriteFile(console, bytes, (DWORD)length, &written, NULL);

    if (newline) {
      WriteFile(console, "\r\n", 2, &written, NULL);
    }
  }

  return process->null_object();
}
#elif (_POSIX_C_SOURCE >= 199309L || _BSD_SOURCE) && defined(_POSIX_THREAD_SAFE_FUNCTIONS)
static Object* write_on_std(const uint8_t* bytes, size_t length, bool is_stdout, bool newline, Process* process) {
  FILE* stream = is_stdout ? stdout : stderr;
  flockfile(stream);
  fwrite_unlocked(bytes, 1, length, stream);
  if (newline) {
    fputc_unlocked('\n', stream);
  } else {
    fflush_unlocked(stream);
  }
  funlockfile(stream);
  return process->null_object();
}
#else
static Object* write_on_std(const uint8_t* bytes, size_t length, bool is_stdout, bool newline, Process* process) {
  FILE* stream = is_stdout ? stdout : stderr;
  fwrite(bytes, 1, length, stream);
  if (newline) {
    fputc('\n', stream);
  } else {
    fflush(stream);
  }
  return process->null_object();
}
#endif

PRIMITIVE(write_on_stdout) {
  ARGS(Blob, message, bool, add_newline);
  bool is_stdout;
  write_on_std(message.address(), message.length(), is_stdout=true, add_newline, process);
  return process->null_object();
}

PRIMITIVE(write_on_stderr) {
  ARGS(Blob, message, bool, add_newline);
  bool is_stdout;
  write_on_std(message.address(), message.length(), is_stdout=false, add_newline, process);
  return process->null_object();
}

PRIMITIVE(main_arguments) {
  uint8* arguments = process->main_arguments();
  if (!arguments) return process->program()->empty_array();

  MessageDecoder decoder(process, arguments);
  Object* decoded = decoder.decode();
  if (decoder.allocation_failed()) {
    decoder.remove_disposing_finalizers();
    FAIL(ALLOCATION_FAILED);
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
    FAIL(ALLOCATION_FAILED);
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
  if (priority != -1 && (priority < 0 || priority > 0xff)) FAIL(OUT_OF_RANGE);
  if (!is_smi(entry)) FAIL(WRONG_OBJECT_TYPE);

  int method_id = Smi::value(entry);
  ASSERT(method_id != -1);
  Method method(process->program()->bytecodes, method_id);

  InitialMemoryManager initial_memory_manager;
  if (!initial_memory_manager.allocate()) FAIL(ALLOCATION_FAILED);

  unsigned size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) {
      return size_encoder.create_error_object(process);
    }
    size = size_encoder.size();
  }

  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  if (buffer == null) FAIL(MALLOC_FAILED);

  MessageEncoder encoder(process, buffer);  // Takes over buffer.
  if (!encoder.encode(arguments)) {
    // Probably an allocation error.
    return encoder.create_error_object(process);
  }

  initial_memory_manager.global_variables = process->program()->global_variables.copy();
  if (!initial_memory_manager.global_variables) FAIL(MALLOC_FAILED);

  int pid = VM::current()->scheduler()->spawn(
      process->program(),
      process->group(),
      priority,
      method,
      &encoder,                  // Takes over encoder.
      &initial_memory_manager);  // Takes over initial memory.
  if (pid == Scheduler::INVALID_PROCESS_ID) {
    FAIL(MALLOC_FAILED);
  }

  return Smi::from(pid);
}

PRIMITIVE(get_generic_resource_group) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  SimpleResourceGroup* resource_group = _new SimpleResourceGroup(process);
  if (!resource_group) FAIL(MALLOC_FAILED);

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
  if (priority < 0) FAIL(INVALID_ARGUMENT);
  return Smi::from(priority);
}

PRIMITIVE(process_set_priority) {
  ARGS(int, pid, int, priority);
  if (priority < 0 || priority > 0xff) FAIL(OUT_OF_RANGE);
  bool success = VM::current()->scheduler()->set_priority(pid, priority);
  if (!success) FAIL(INVALID_ARGUMENT);
  return process->null_object();
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
    FAIL(INVALID_ARGUMENT);
  }
  result &= Interpreter::COMPARE_RESULT_MASK;
  return Smi::from(result + Interpreter::COMPARE_RESULT_BIAS);
}

PRIMITIVE(min_special_compare_to) {
  ARGS(Object, lhs, Object, rhs);
  int result = Interpreter::compare_numbers(lhs, rhs);
  if (result == Interpreter::COMPARE_FAILED) {
    FAIL(INVALID_ARGUMENT);
  }
  result &= Interpreter::COMPARE_FLAG_LESS_FOR_MIN;
  return BOOL(result != 0);
}

#define SMI_COMPARE(op) { \
  ARGS(word, receiver, Object, arg); \
  if (is_smi(arg)) return BOOL(receiver op Smi::value(arg)); \
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE); \
  return BOOL(((int64) receiver) op LargeInteger::cast(arg)->value()); \
}

#define DOUBLE_COMPARE(op) { \
  ARGS(double, receiver, double, arg); \
  return BOOL(receiver op arg); \
}

#define LARGE_INTEGER_COMPARE(op) { \
  ARGS(LargeInteger, receiver, Object, arg); \
  if (is_smi(arg)) return BOOL(receiver->value() op (int64) Smi::value(arg)); \
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE); \
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
  if (!(0 <= start && start <= end && end <= bytes.length())) FAIL(OUT_OF_BOUNDS);
  return BOOL(Utils::is_valid_utf_8(bytes.address() + start, end - start));
}

PRIMITIVE(byte_array_convert_to_string) {
  ARGS(Blob, bytes, int, start, int, end);
  if (!(0 <= start && start <= end && end <= bytes.length())) FAIL(OUT_OF_BOUNDS);
  if (!Utils::is_valid_utf_8(bytes.address() + start, end - start)) FAIL(ILLEGAL_UTF_8);
  return process->allocate_string_or_error(char_cast(bytes.address()) + start, end - start);
}

PRIMITIVE(blob_index_of) {
  ARGS(Blob, bytes, int, byte, word, from, word, to);
  if (!(0 <= from && from <= to && to <= bytes.length())) FAIL(OUT_OF_BOUNDS);
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
  word len = to - from;
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
  ARGS(int64, accumulator, word, width, Blob, data, word, from, word, to, Object, table_object);
  if ((width != 0 && width < 8) || width > 64) FAIL(INVALID_ARGUMENT);
  bool big_endian = width != 0;
  if (to == from) return _raw_accumulator;
  if (from < 0 || to > data.length() || from > to) FAIL(OUT_OF_BOUNDS);
  Array* table = get_array_from_list(table_object, process);
  const uint8* byte_table = null;
  if (table) {
    if (table->length() != 0x100) FAIL(INVALID_ARGUMENT);
  } else {
    Blob blob;
    if (!table_object->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    if (blob.length() != 0x100) FAIL(INVALID_ARGUMENT);
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
      INT64_VALUE_OR_WRONG_TYPE(int_table_entry, table_entry);
      entry = int_table_entry;
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
  if (rune < 0 || rune > Utils::MAX_UNICODE) FAIL(INVALID_ARGUMENT);
  // Don't allow surrogates.
  if (Utils::MIN_SURROGATE <= rune && rune <= Utils::MAX_SURROGATE) FAIL(INVALID_ARGUMENT);
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
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}

PRIMITIVE(string_write_to_byte_array) {
  ARGS(Blob, source_bytes, MutableBlob, dest, word, from, word, to, word, dest_index);
  if (to == from) return _raw_dest;
  if (from < 0 || to > source_bytes.length() || from > to) FAIL(OUT_OF_BOUNDS);
  if (dest_index + to - from > dest.length()) FAIL(OUT_OF_BOUNDS);
  memcpy(&dest.address()[dest_index], &source_bytes.address()[from], to - from);
  return _raw_dest;
}

PRIMITIVE(put_uint_big_endian) {
  ARGS(Object, unused, MutableBlob, dest, int, width, word, offset, int64, value);
  USE(unused);
  unsigned unsigned_width = width;
  uword unsigned_offset = offset;
  uword length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width > 9 || unsigned_offset + unsigned_width > length) {
    FAIL(OUT_OF_BOUNDS);
  }
  for (int i = width - 1; i >= 0; i--) {
    dest.address()[offset + i] = value;
    value >>= 8;
  }
  return process->null_object();
}

PRIMITIVE(put_uint_little_endian) {
  ARGS(Object, unused, MutableBlob, dest, int, width, word, offset, int64, value);
  USE(unused);
  unsigned width_minus_1 = width - 1;  // This means width 0 is rejected.
  uword unsigned_offset = offset;
  uword length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || width_minus_1 >= 8 || unsigned_offset + width_minus_1 >= length) {
    FAIL(OUT_OF_BOUNDS);
  }
  for (uword i = 0; i <= width_minus_1; i++) {
    dest.address()[offset + i] = value;
    value >>= 8;
  }
  return process->null_object();
}

PRIMITIVE(put_float_32_little_endian) {
  ARGS(Object, unused, MutableBlob, dest, word, offset, double, value);
  USE(unused);
  uword unsigned_offset = offset;
  uword length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_offset + 4 >= length) {
    FAIL(OUT_OF_BOUNDS);
  }
  float raw = value;
  memcpy(dest.address() + offset, &raw, sizeof raw);
  return process->null_object();
}

PRIMITIVE(put_float_64_little_endian) {
  ARGS(Object, unused, MutableBlob, dest, word, offset, double, value);
  USE(unused);
  uword unsigned_offset = offset;
  uword length = dest.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_offset + 8 >= length) {
    FAIL(OUT_OF_BOUNDS);
  }
  memcpy(dest.address() + offset, &value, sizeof value);
  return process->null_object();
}

PRIMITIVE(read_uint_big_endian) {
  ARGS(Object, unused, Blob, source, int, width, word, offset);
  USE(unused);
  unsigned unsigned_width = width;
  uword unsigned_offset = offset;
  uword length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width > 8 || unsigned_offset + unsigned_width > length) {
    FAIL(OUT_OF_BOUNDS);
  }
  uint64 value = 0;
  for (int i = 0; i < width; i++) {
    value <<= 8;
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_uint_little_endian) {
  ARGS(Object, unused, Blob, source, int, width, word, offset);
  USE(unused);
  unsigned unsigned_width = width;
  uword unsigned_offset = offset;
  uword length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width > 8 || unsigned_offset + unsigned_width > length) {
    FAIL(OUT_OF_BOUNDS);
  }
  uint64 value = 0;
  for (word i = width - 1; i >= 0; i--) {
    value <<= 8;
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_int_big_endian) {
  ARGS(Object, unused, Blob, source, int, width, word, offset);
  USE(unused);
  unsigned width_minus_1 = width - 1;  // This means size 0 is rejected.
  uword unsigned_offset = offset;
  uword length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || width_minus_1 >= 8 || unsigned_offset + width_minus_1 >= length) {
    FAIL(OUT_OF_BOUNDS);
  }
  int64 value = static_cast<int8>(source.address()[offset]);  // Sign extend.
  for (uword i = 1; i <= width_minus_1; i++) {
    value <<= 8;
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_int_little_endian) {
  ARGS(Object, unused, Blob, source, int, width, word, offset);
  USE(unused);
  unsigned width_minus_1 = width - 1;  // This means size 0 is rejected.
  uword unsigned_offset = offset;
  uword length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || width_minus_1 >= 8 || unsigned_offset + width_minus_1 >= length) {
    FAIL(OUT_OF_BOUNDS);
  }
  int64 value = static_cast<int8>(source.address()[offset + width_minus_1]);  // Sign extend.
  for (uword i = width_minus_1; i != 0; i--) {
    value <<= 8;
    value |= source.address()[offset + i - 1];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(program_name) {
  if (Flags::program_name == null) return process->null_object();
  return process->allocate_string_or_error(Flags::program_name);
}

PRIMITIVE(program_path) {
  if (Flags::program_path == null) return process->null_object();
  return process->allocate_string_or_error(Flags::program_path);
}

PRIMITIVE(smi_add) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    if ((receiver > 0) && (other > Smi::MAX_SMI_VALUE - receiver)) goto overflow;
    if ((receiver < 0) && (other < Smi::MIN_SMI_VALUE - receiver)) goto overflow;
    return Smi::from(receiver + other);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::value(arg) : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver + other, process);
}

PRIMITIVE(smi_subtract) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    if ((receiver < 0) && (other > Smi::MAX_SMI_VALUE + receiver)) goto overflow;
    if ((receiver > 0) && (other < Smi::MIN_SMI_VALUE + receiver)) goto overflow;
    return Smi::from(receiver - other);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::value(arg) : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver - other, process);
}

PRIMITIVE(smi_multiply) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    word result;
    if (__builtin_mul_overflow(receiver, other << 1, &result)) goto overflow;
    Smi* r = reinterpret_cast<Smi*>(result);
    ASSERT(r == Smi::from(result >> 1));
    return r;
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::value(arg) : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver * other, process);
}

PRIMITIVE(smi_divide) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    return Smi::from(receiver / other);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  int64 other = is_smi(arg) ? (int64) Smi::value(arg) : LargeInteger::cast(arg)->value();
  return Primitive::integer((int64) receiver / other, process);
}

PRIMITIVE(smi_mod) {
  ARGS(word, receiver, Object, arg);
  if (arg == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    return Smi::from(receiver % other);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  int64 other = is_smi(arg) ? (int64) Smi::value(arg) : LargeInteger::cast(arg)->value();
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
      snprintf(buffer, sizeof(buffer), "%" PRIo64, value);
      break;
    case 10:
      snprintf(buffer, sizeof(buffer), "%" PRId64, value);
      break;
    case 16:
      snprintf(buffer, sizeof(buffer), "%" PRIx64, value);
      break;
    default:
      buffer[0] = '\0';
  }
  return process->allocate_string_or_error(buffer);
}

PRIMITIVE(int64_to_string) {
  ARGS(int64, value, int, base);
  if (!(2 <= base && base <= 36)) FAIL(OUT_OF_RANGE);
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
  if (is_smi(arg)) result += Smi::value(arg);
  else if (is_large_integer(arg)) result += LargeInteger::cast(arg)->value();
  else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_subtract) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result -= Smi::value(arg);
  else if (is_large_integer(arg)) result -= LargeInteger::cast(arg)->value();
  else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_multiply) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result *= Smi::value(arg);
  else if (is_large_integer(arg)) result *= LargeInteger::cast(arg)->value();
  else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_divide) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    if (Smi::value(arg) == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    result /= Smi::value(arg);
  } else if (is_large_integer(arg)) {
    ASSERT(LargeInteger::cast(arg)->value() != 0LL);
    result /= LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_mod) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    if (Smi::value(arg) == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    result %= Smi::value(arg);
  } else if (is_large_integer(arg)) {
    ASSERT(LargeInteger::cast(arg)->value() != 0LL);
    result %= LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
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
    result &= Smi::value(arg);
  } else if (is_large_integer(arg)) {
    result &= LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_or) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    result |= Smi::value(arg);
  } else if (is_large_integer(arg)) {
    result |= LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_xor) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) {
    result ^= Smi::value(arg);
  } else if (is_large_integer(arg)) {
    result ^= LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_shift_right) {
  ARGS(LargeInteger, receiver, int64, bits_to_shift);
  if (bits_to_shift < 0) FAIL(NEGATIVE_ARGUMENT);
  if (bits_to_shift >= LARGE_INT_BIT_SIZE) return Primitive::integer(receiver->value() < 0 ? -1 : 0, process);
  return Primitive::integer(receiver->value() >> bits_to_shift, process);
}

PRIMITIVE(large_integer_unsigned_shift_right) {
  ARGS(LargeInteger, receiver, int64, bits_to_shift);
  if (bits_to_shift < 0) FAIL(NEGATIVE_ARGUMENT);
  if (bits_to_shift >= LARGE_INT_BIT_SIZE) return Smi::from(0);
  uint64 value = static_cast<uint64>(receiver->value());
  int64 result = static_cast<int64>(value >> bits_to_shift);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_shift_left) {
  ARGS(LargeInteger, receiver, int64, number_of_bits);
  if (number_of_bits < 0) FAIL(NEGATIVE_ARGUMENT);
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
  ARGS(double, receiver, int, precision);
  if (precision < 0 || precision > 15) FAIL(INVALID_ARGUMENT);
  if (isnan(receiver)) FAIL(OUT_OF_RANGE);
  if (receiver > pow(10,54)) return _raw_receiver;
  int factor = pow(10, precision);
  return Primitive::allocate_double(round(receiver * factor) / factor, process);
}

PRIMITIVE(int_parse) {
  ARGS(Blob, input, word, from, word, to, int, block_arg_dont_use_this);
  if (!(0 <= from && from < to && to <= input.length())) FAIL(OUT_OF_RANGE);
  // Difficult cases, handled by Toit code.  If the ASCII length is always less
  // than 18 we don't have to worry about 64 bit overflow.
  if (to - from > 18) FAIL(OUT_OF_RANGE);
  uint64 result = 0;
  bool negative = false;
  word index = from;
  const uint8* in = input.address();
  if (in[index] == '-') {
    negative = true;
    index++;
    if (index == to) FAIL(INVALID_ARGUMENT);
  }
  for (; index < to; index++) {
    char c = in[index];
    if ('0' <= c && c <= '9') {
      result *= 10;
      result += c - '0';
    } else if (c == '_') {
      if (index == from || index == to - 1 || (negative && index == from + 1)) FAIL(INVALID_ARGUMENT);
    } else {
      FAIL(INVALID_ARGUMENT);
    }
  }
  return Primitive::integer(negative ? -result : result, process);
}

PRIMITIVE(float_parse) {
  ARGS(Blob, input, word, from, word, to);
  if (!(0 <= from && from < to && to <= input.length())) FAIL(OUT_OF_RANGE);
  const char* from_ptr = char_cast(input.address() + from);
  // strtod removes leading whitespace, but float.parse doesn't accept it.
  if (isspace(*from_ptr)) FAIL(ERROR);
  bool needs_free = false;
  char* copied;
  if (!is_string(_raw_input) || to != input.length()) {  // Strings are null-terminated.
    // There is no way to tell strtod to stop early.
    // We have to copy the area we are interested in.
    copied = reinterpret_cast<char*>(malloc(to - from + 1));
    if (copied == null) FAIL(ALLOCATION_FAILED);
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
  if (!succeeded) FAIL(ERROR);
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
  if ((static_cast<uint64>(raw) >> 32) != 0) FAIL(OUT_OF_RANGE);
  double value = bit_cast<float>(static_cast<uint32>(raw));
  return Primitive::allocate_double(value, process);
}

PRIMITIVE(time) {
  ARGS(bool, since_wakeup);
  int64 timestamp = since_wakeup ? OS::get_monotonic_time() : OS::get_system_time();
  return Primitive::integer(timestamp, process);
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
  if (result == null) FAIL(ALLOCATION_FAILED);
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
  if (daylight_saving_is_active == process->null_object()) {
    decomposed.tm_isdst = -1;
  } else if (daylight_saving_is_active == process->true_object()) {
    decomposed.tm_isdst = 1;
  } else if (daylight_saving_is_active == process->false_object()) {
    decomposed.tm_isdst = 0;
  } else {
    FAIL(WRONG_OBJECT_TYPE);
  }
  errno = 0;
  int64 result = mktime(&decomposed);
  if (result == -1 && errno != 0) {
    return process->null_object();
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
    return process->null_object();
  }
  const char* prefix = "TZ=";
  const int prefix_size = strlen(prefix);
  int buffer_size = prefix_size + length + 1;
  char* tz_buffer = static_cast<char*>(malloc(buffer_size));
  if (tz_buffer == null) FAIL(ALLOCATION_FAILED);
  strcpy(tz_buffer, prefix);
  memcpy(tz_buffer + prefix_size, rules, buffer_size - prefix_size);
  tz_buffer[buffer_size - 1] = '\0';
  putenv((char*)("TZ"));
  putenv(tz_buffer);
  tzset();
  free(current_buffer);
  current_buffer = tz_buffer;
  return process->null_object();
}

PRIMITIVE(platform) {
  const char* platform_name = OS::get_platform();
  return process->allocate_string_or_error(platform_name, strlen(platform_name));
}

PRIMITIVE(architecture) {
  const char* architecture_name = OS::get_architecture();
  return process->allocate_string_or_error(architecture_name, strlen(architecture_name));
}

PRIMITIVE(bytes_allocated_delta) {
  return Primitive::integer(process->bytes_allocated_delta(), process);
}

PRIMITIVE(process_stats) {
  ARGS(Object, list_object, int, group, int, id, Object, gc_count);

  if (gc_count != process->null_object()) {
    INT64_VALUE_OR_WRONG_TYPE(word_gc_count, gc_count);
    // Return ALLOCATION_FAILED until we cause a full GC.
    if (process->gc_count(FULL_GC) == word_gc_count) FAIL(ALLOCATION_FAILED);
  }

  Array* result = get_array_from_list(list_object, process);
  if (result == null) FAIL(INVALID_ARGUMENT);
  if (group == -1 || id == -1) {
    if (group != -1 || id != -1) FAIL(INVALID_ARGUMENT);
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
  return process->null_object();
}

PRIMITIVE(add_entropy) {
  PRIVILEGED;
  ARGS(Blob, data);
  EntropyMixer::instance()->add_entropy(data.address(), data.length());
  return process->null_object();
}

PRIMITIVE(count_leading_zeros) {
  ARGS(int64, v);
  return Smi::from(Utils::clz(v));
}

PRIMITIVE(popcount) {
  ARGS(int64, v);
  return Smi::from(Utils::popcount(v));
}

// Treats two ints as vectors of 8 bytes and compares them
// bytewise for equality.  Returns an 8 bit packed result with
// 1 for equality and 0 for inequality.
PRIMITIVE(int_vector_equals) {
  ARGS(int64, x, int64, y);
#if defined(__x86_64__) || defined(_M_X64)
  __m128i x128 = _mm_set_epi64x(0, x);
  __m128i y128 = _mm_set_epi64x(0, y);
  __m128i mask = _mm_cmpeq_epi8(x128, y128);
  int t = _mm_movemask_epi8(mask);
  return Smi::from(t & 0xff);
#else
  uint64 combined = x ^ y;
  int result = 0xff;
  for (int i = 0; combined != 0; i++) {
    if ((combined & 0xff) != 0) result &= ~(1 << i);
    combined >>= 8;
  }
  return Smi::from(result);
#endif
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
  ARGS(Blob, bytes, word, offset);
  if (offset < 0) FAIL(INVALID_ARGUMENT);
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
  ARGS(Blob, bytes, word, offset);
  if (offset < 0) FAIL(INVALID_ARGUMENT);
  word i = offset;
  for ( ; i < bytes.length(); i++) {
    uint8 c = bytes.address()[i];
    if (c != ' ' && c != '\n' && c != '\t' && c != '\r') return Smi::from(i);
  }
  return Smi::from(i);
}

PRIMITIVE(compare_simple_json_string) {
  ARGS(Blob, bytes, word, offset, StringOrSlice, string);
  if (offset < 0) FAIL(INVALID_ARGUMENT);
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
  ARGS(Blob, bytes, word, offset);
  if (offset < 0 || offset >= bytes.length() - 1) FAIL(INVALID_ARGUMENT);
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
  if (!receiver->byte_content(process->program(), &receiver_blob, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
  if (!other->byte_content(process->program(), &other_blob, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
  if (receiver_blob.length() != other_blob.length()) return BOOL(false);
  return BOOL(memcmp(receiver_blob.address(), other_blob.address(), receiver_blob.length()) == 0);
}

PRIMITIVE(string_compare) {
  ARGS(Object, receiver, Object, other)
  if (receiver == other) return Smi::from(0);
  Blob receiver_blob;
  Blob other_blob;
  if (!receiver->byte_content(process->program(), &receiver_blob, STRINGS_ONLY)) FAIL(WRONG_OBJECT_TYPE);
  if (!other->byte_content(process->program(), &other_blob, STRINGS_ONLY)) FAIL(WRONG_OBJECT_TYPE);
  return Smi::from(String::compare(receiver_blob.address(), receiver_blob.length(),
                                   other_blob.address(), other_blob.length()));
}

PRIMITIVE(string_rune_count) {
  ARGS(Blob, bytes)
  word count = 0;
  const uword WORD_MASK = WORD_SIZE - 1;
  const uint8* address = bytes.address();
  word len = bytes.length();
  // This algorithm counts the runes in word-sized chunks of UTF-8.
  // We have to ensure that the memory reads are word aligned to avoid memory
  // faults.
  // The first mask will make sure we skip over the bytes we don't need.
  word skipped_start_bytes = reinterpret_cast<uword>(address) & WORD_MASK;
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

  return Smi::from(count);
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
  if (base != 2 && base != 8 && base != 16) FAIL(INVALID_ARGUMENT);
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
  if (precision == process->null_object()) {
    format = "%.*lg";
  } else {
    format = "%.*lf";
    if (is_large_integer(precision)) FAIL(OUT_OF_BOUNDS);
    if (!is_smi(precision)) FAIL(WRONG_OBJECT_TYPE);
    prec = Smi::value(precision);
    if (prec < 0 || prec > 64) FAIL(OUT_OF_BOUNDS);
  }
  char* buffer = safe_double_print(format, prec, receiver);
  if (buffer == null) FAIL(MALLOC_FAILED);
  Object* result = process->allocate_string(buffer);
  free(buffer);
  if (result == null) FAIL(ALLOCATION_FAILED);
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
    if (isnan(value)) FAIL(INVALID_ARGUMENT);
    if (value < (double) INT64_MIN || value >= (double) INT64_MAX) FAIL(OUT_OF_RANGE);
    return Primitive::integer((int64) value, process);
  }
  FAIL(WRONG_OBJECT_TYPE);
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
                              const uint8* bytes_a, word len_a,
                              const uint8* bytes_b, word len_b) {
  String* result = process->allocate_string(len_a + len_b);
  if (result == null) return null;
  // Initialize object.
  String::MutableBytes bytes(result);
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
  if (!is_validated_string(process->program(), receiver)) FAIL(WRONG_OBJECT_TYPE);
  if (!is_validated_string(process->program(), other)) FAIL(WRONG_OBJECT_TYPE);
  Blob receiver_blob;
  Blob other_blob;
  // These should always succeed, as the operator already checks the objects are strings.
  if (!receiver->byte_content(process->program(), &receiver_blob, STRINGS_ONLY)) FAIL(WRONG_OBJECT_TYPE);
  if (!other->byte_content(process->program(), &other_blob, STRINGS_ONLY)) FAIL(WRONG_OBJECT_TYPE);
  result = concat_strings(process,
                          receiver_blob.address(), receiver_blob.length(),
                          other_blob.address(), other_blob.length());
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}

static inline bool utf_8_continuation_byte(int c) {
  return (c & 0xc0) == 0x80;
}

PRIMITIVE(string_slice) {
  ARGS(String, receiver, word, from, word, to);
  String::Bytes bytes(receiver);
  word length = bytes.length();
  if (from == 0 && to == length) return receiver;
  if (from < 0 || to > length || from > to) FAIL(OUT_OF_BOUNDS);
  if (from != length) {
    int first = bytes.at(from);
    if (utf_8_continuation_byte(first)) FAIL(ILLEGAL_UTF_8);
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
    if (utf_8_continuation_byte(first_after)) FAIL(ILLEGAL_UTF_8);
  }
  ASSERT(from >= 0);
  ASSERT(to <= receiver->length());  // Checked above.
  ASSERT(from < to);
  word result_len = to - from;
  String* result = process->allocate_string(result_len);
  if (result == null) FAIL(ALLOCATION_FAILED);
  // Initialize object.
  String::MutableBytes result_bytes(result);
  result_bytes._initialize(0, receiver, from, to - from);
  return result;
}

PRIMITIVE(concat_strings) {
  ARGS(Array, array);
  Program* program = process->program();
  // First make sure we have an array of strings.
  for (word index = 0; index < array->length(); index++) {
    if (!is_validated_string(process->program(), array->at(index))) FAIL(WRONG_OBJECT_TYPE);
  }
  word length = 0;
  for (word index = 0; index < array->length(); index++) {
    Blob blob;
    HeapObject::cast(array->at(index))->byte_content(program, &blob, STRINGS_ONLY);
    length += blob.length();
  }
  String* result = process->allocate_string(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  String::MutableBytes bytes(result);
  word pos = 0;
  for (word index = 0; index < array->length(); index++) {
    Blob blob;
    HeapObject::cast(array->at(index))->byte_content(program, &blob, STRINGS_ONLY);
    word len = blob.length();
    bytes._initialize(pos, blob.address(), 0, len);
    pos += len;
  }
  return result;
}

PRIMITIVE(string_at) {
  ARGS(StringOrSlice, receiver, int, index);
  if (index < 0 || index >= receiver.length()) FAIL(OUT_OF_BOUNDS);
  int c = receiver.address()[index] & 0xff;
  if (c <= Utils::MAX_ASCII) return Smi::from(c);
  // Invalid index.  Return null.  This means you can still scan for ASCII characters very simply.
  if (!Utils::is_utf_8_prefix(c)) return process->null_object();
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
  if (index < 0 || index >= receiver.length()) FAIL(OUT_OF_BOUNDS);
  int c = receiver.address()[index] & 0xff;
  return Smi::from(c);
}

PRIMITIVE(utf_16_to_string) {
  ARGS(Blob, utf_16);
  if ((utf_16.length() & 1) != 0) FAIL(INVALID_ARGUMENT);
  if (utf_16.length() > 0x3fffffff) FAIL(OUT_OF_BOUNDS);

  int utf_8_length = Utils::utf_16_to_8(
      reinterpret_cast<const uint16*>(utf_16.address()),
      utf_16.length() >> 1);

  String* result = process->allocate_string(utf_8_length);
  if (result == null) FAIL(ALLOCATION_FAILED);

  String::MutableBytes utf_8(result);

  Utils::utf_16_to_8(
      reinterpret_cast<const uint16*>(utf_16.address()),
      utf_16.length() >> 1,
      utf_8.address(),
      utf_8.length());

  return result;
}

PRIMITIVE(string_to_utf_16) {
  ARGS(StringOrSlice, utf_8);
  if (utf_8.length() > 0xfffffff) FAIL(OUT_OF_BOUNDS);

  int utf_16_length = Utils::utf_8_to_16(
      utf_8.address(),
      utf_8.length());

  ByteArray* result = process->allocate_byte_array(utf_16_length << 1);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);

  Utils::utf_8_to_16(
      utf_8.address(),
      utf_8.length(),
      reinterpret_cast<uint16*>(bytes.address()),
      utf_16_length);

  return result;
}

PRIMITIVE(array_length) {
  ARGS(Array, receiver);
  return Smi::from(receiver->length());
}

PRIMITIVE(array_at) {
  ARGS(Array, receiver, int, index);
  if (index >= 0 && index < receiver->length()) return receiver->at(index);
  FAIL(OUT_OF_BOUNDS);
}

PRIMITIVE(array_at_put) {
  ARGS(Array, receiver, int, index, Object, value);
  if (index >= 0 && index < receiver->length()) {
    receiver->at_put(index, value);
    return value;
  }
  FAIL(OUT_OF_BOUNDS);
}

// Allocates a new array and copies old_length elements from the old array into
// the new one.
PRIMITIVE(array_expand) {
  ARGS(Array, old, word, old_length, word, length, Object, filler);
  if (length == 0) return process->program()->empty_array();
  if (length < 0) FAIL(OUT_OF_BOUNDS);
  if (length > Array::ARRAYLET_SIZE) FAIL(OUT_OF_RANGE);
  if (old_length < 0 || old_length > old->length()) FAIL(OUT_OF_RANGE);
  Object* result = process->object_heap()->allocate_array(length, filler);
  if (result == null) FAIL(ALLOCATION_FAILED);
  Array* new_array = Array::cast(result);
  new_array->copy_from(old, Utils::min(length, old_length));
  if (old_length < length) new_array->fill(old_length, filler);
  return new_array;
}

// Memmove between arrays.
PRIMITIVE(array_replace) {
  ARGS(Array, dest, word, index, Array, source, word, from, word, to);
  word dest_length = dest->length();
  word source_length = source->length();
  if (index < 0 || from < 0 || from > to || to > source_length) FAIL(OUT_OF_BOUNDS);
  word len = to - from;
  if (index + len > dest_length) FAIL(OUT_OF_BOUNDS);
  // Our write barrier is only there to record the presence of pointers
  // from old-space to new-space, and the resolution is per-object.  If
  // there were no pointers from old-space to new-space then an intra-
  // array copy is not going to create any.
  if (len != 0 && dest != source) GcMetadata::insert_into_remembered_set(dest);
  memmove(dest->content() + index * WORD_SIZE,
          source->content() + from * WORD_SIZE,
          len * WORD_SIZE);
  return process->null_object();
}

PRIMITIVE(array_new) {
  ARGS(int, length, Object, filler);
  if (length == 0) return process->program()->empty_array();
  if (length < 0) FAIL(OUT_OF_BOUNDS);
  if (length > Array::ARRAYLET_SIZE) FAIL(OUT_OF_RANGE);
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
        word size = Smi::value(list->at(1));
        if (size < array->length()) {
          list->at_put(1, Smi::from(size + 1));
          array->at_put(size, value);
          return process->null_object();
        }
      } else {
        // Large array backing case.
        Object* size_object = list->at(1);
        if (is_smi(size_object)) {
          word size = Smi::value(size_object);
          if (Smi::is_valid(size + 1)) {
            if (Interpreter::fast_at(process, array_object, size_object, true, &value)) {
              list->at_put(1, Smi::from(size + 1));
              return process->null_object();
            }
          }
        }
      }
    }
  }
  FAIL(INVALID_ARGUMENT);  // Handled in Toit code.
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
  FAIL(WRONG_OBJECT_TYPE);
}

PRIMITIVE(byte_array_at) {
  ARGS(ByteArray, receiver, int, index);
  if (!receiver->has_external_address() || receiver->external_tag() == RawByteTag || receiver->external_tag() == MappedFileTag) {
    ByteArray::Bytes bytes(receiver);
    if (!bytes.is_valid_index(index)) FAIL(OUT_OF_BOUNDS);
    return Smi::from(bytes.at(index));
  }
  FAIL(WRONG_OBJECT_TYPE);
}

PRIMITIVE(byte_array_at_put) {
  ARGS(ByteArray, receiver, int, index, int64, value);
  if (!receiver->has_external_address() || receiver->external_tag() == RawByteTag) {
    ByteArray::Bytes bytes(receiver);
    if (!bytes.is_valid_index(index)) FAIL(OUT_OF_BOUNDS);
    bytes.at_put(index, (uint8) value);
    return Smi::from((uint8) value);
  }
  FAIL(WRONG_OBJECT_TYPE);
}

PRIMITIVE(byte_array_new) {
  ARGS(int, length, int, filler);
  if (length < 0) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  if (filler != 0) {
    ByteArray::Bytes bytes(result);
    memset(bytes.address(), filler, length);
  }
  return result;
}

PRIMITIVE(byte_array_new_external) {
  ARGS(int, length);
  if (length < 0) FAIL(OUT_OF_BOUNDS);
  bool force_external = true;
  ByteArray* result = process->allocate_byte_array(length, force_external);
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}

PRIMITIVE(byte_array_replace) {
  ARGS(MutableBlob, receiver, int, index, Blob, source_object, int, from, int, to);
  if (index < 0 || from < 0 || to < 0 || to > source_object.length()) FAIL(OUT_OF_BOUNDS);
  word length = to - from;
  if (length < 0 || index + length > receiver.length()) FAIL(OUT_OF_BOUNDS);

  uint8* dest = receiver.address() + index;
  const uint8* source = source_object.address() + from;
  memmove(dest, source, length);
  return process->null_object();
}

PRIMITIVE(smi_unary_minus) {
  ARGS(Object, receiver);
  if (!is_smi(receiver)) FAIL(WRONG_OBJECT_TYPE);
  // We can't assume that `-x` is still a smi, as -MIN_SMI_VALUE > MAX_SMI_VALUE.
  // However, it must fit a `word` as smis are smaller than words.
  word value = Smi::value(receiver);
  return Primitive::integer(-value, process);
}

PRIMITIVE(smi_not) {
  ARGS(word, receiver);
  return Smi::from(~receiver);
}

PRIMITIVE(smi_and) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) return Smi::from(receiver & Smi::value(arg));
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(((int64) receiver) & LargeInteger::cast(arg)->value() , process);
}

PRIMITIVE(smi_or) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) return Smi::from(receiver | Smi::value(arg));
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(((int64) receiver) | LargeInteger::cast(arg)->value() , process);
}

PRIMITIVE(smi_xor) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) return Smi::from(receiver ^ Smi::value(arg));
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(((int64) receiver) ^ LargeInteger::cast(arg)->value() , process);
}

PRIMITIVE(smi_shift_right) {
  ARGS(word, receiver, int64, bits_to_shift);
  if (bits_to_shift < 0) FAIL(NEGATIVE_ARGUMENT);
  if (bits_to_shift >= WORD_BIT_SIZE) return Smi::from(receiver < 0 ? -1 : 0);
  return Smi::from(receiver >> bits_to_shift);
}

PRIMITIVE(smi_unsigned_shift_right) {
  ARGS(Object, receiver, int64, bits_to_shift);
  if (!is_smi(receiver)) FAIL(WRONG_OBJECT_TYPE);
  if (bits_to_shift < 0) FAIL(NEGATIVE_ARGUMENT);
  if (bits_to_shift >= 64) return Smi::zero();
  uint64 value = static_cast<uint64>(Smi::value(receiver));
  int64 result = static_cast<int64>(value >> bits_to_shift);
  return Primitive::integer(result, process);
}

PRIMITIVE(smi_shift_left) {
  ARGS(Object, receiver, int64, number_of_bits);
  if (!is_smi(receiver)) FAIL(WRONG_OBJECT_TYPE);
  if (number_of_bits < 0) FAIL(NEGATIVE_ARGUMENT);
  if (number_of_bits >= 64) return Smi::zero();
  int64 value = Smi::value(receiver);
  return Primitive::integer(value << number_of_bits, process);
}

PRIMITIVE(task_new) {
  ARGS(Instance, code);
  Task* task = process->object_heap()->allocate_task();
  if (task == null) FAIL(ALLOCATION_FAILED);
  Method entry = process->program()->entry_task();
  if (!entry.is_valid()) FATAL("Cannot locate task entry method");
  Task* current = process->object_heap()->task();

  Interpreter* interpreter = process->scheduler_thread()->interpreter();
  interpreter->store_stack();

  process->object_heap()->set_task(task);
  interpreter->load_stack();
  interpreter->prepare_task(entry, code);
  interpreter->store_stack();

  process->object_heap()->set_task(current);
  interpreter->load_stack();

  return task;
}

PRIMITIVE(task_transfer) {
  ARGS(Task, to, bool, detach_stack);
  Task* from = process->object_heap()->task();
  if (from != to) {
    // Make sure we don't transfer to a dead task.
    if (!to->has_stack()) FAIL(ERROR);
    Interpreter* interpreter = process->scheduler_thread()->interpreter();
    interpreter->store_stack();
    // Remove the link from the task to the stack if requested.
    if (detach_stack) from->detach_stack();
    process->object_heap()->set_task(to);
    interpreter->load_stack();
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
  if (buffer == null) FAIL(MALLOC_FAILED);

  MessageEncoder encoder(process, buffer);  // Takes over buffer.
  if (!encoder.encode(array)) {
    return encoder.create_error_object(process);
  }

  // Takes over the buffer and neutralizes the MessageEncoder.
  SystemMessage* message = _new SystemMessage(type, process->group()->id(), process->id(), &encoder);
  if (message == null) FAIL(MALLOC_FAILED);

  // One of the calls below takes over the SystemMessage.
  message_err_t result = (process_id >= 0)
      ? VM::current()->scheduler()->send_message(process_id, message)
      : VM::current()->scheduler()->send_system_message(message);
  return BOOL(result == MESSAGE_OK);
}

PRIMITIVE(pid_for_external_id) {
  ARGS(String, id)
  return Smi::from(pid_for_external_id(id));
}

Object* MessageEncoder::create_error_object(Process* process) {
  Object* result = null;
  if (malloc_failed_) {
    FAIL(MALLOC_FAILED);
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
  FAIL(WRONG_OBJECT_TYPE);
}

PRIMITIVE(task_has_messages) {
  ObjectHeap* heap = process->object_heap();
  if (heap->max_external_allocation() < 0) FAIL(ALLOCATION_FAILED);

  if (heap->has_finalizer_to_run()) {
    return BOOL(true);
  } else {
    Message* message = process->peek_message();
    return BOOL(message != null);
  }
}

PRIMITIVE(task_receive_message) {
  ObjectHeap* heap = process->object_heap();
  if (heap->has_finalizer_to_run()) {
    return heap->next_finalizer_to_run();
  }

  Message* message = process->peek_message();
  MessageType message_type = message->message_type();
  Object* result = process->null_object();

  if (message_type == MESSAGE_MONITOR_NOTIFY) {
    ObjectNotifyMessage* object_notify = static_cast<ObjectNotifyMessage*>(message);
    ObjectNotifier* notifier = object_notify->object_notifier();
    if (notifier != null) result = notifier->object();
  } else if (message_type == MESSAGE_SYSTEM) {
    Array* array = process->object_heap()->allocate_array(4, Smi::from(0));
    if (array == null) FAIL(ALLOCATION_FAILED);
    SystemMessage* system_message = static_cast<SystemMessage*>(message);
    MessageDecoder decoder(process, system_message->data());

    Object* decoded = decoder.decode();
    if (decoder.allocation_failed()) {
      decoder.remove_disposing_finalizers();
      FAIL(ALLOCATION_FAILED);
    }
    decoder.register_external_allocations();
    system_message->free_data_but_keep_externals();

    array->at_put(0, Smi::from(system_message->type()));
    array->at_put(1, Smi::from(system_message->gid()));
    array->at_put(2, Smi::from(system_message->pid()));
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
  bool make_weak = false;
  if (!object->can_be_toit_finalized(process->program())) {
    if (!is_instance(object) || Instance::cast(object)->class_id() != process->program()->map_class_id()) {
      FAIL(WRONG_OBJECT_TYPE);
    }
    make_weak = true;
  }
  ASSERT(is_instance(object));  // Guaranteed by can_be_toit_finalized.
  // Objects on the program heap will never die, so it makes no difference
  // whether we have a finalizer on them.
  if (!object->on_program_heap(process)) {
    if (object->has_active_finalizer()) FAIL(ALREADY_EXISTS);
    if (!process->object_heap()->add_callable_finalizer(Instance::cast(object), finalizer, make_weak)) FAIL(MALLOC_FAILED);
  }
  return process->null_object();
}

PRIMITIVE(remove_finalizer) {
  ARGS(HeapObject, object)
  bool result = object->has_active_finalizer();
  // We don't remove it from the finalizer list, so that must happen at the
  // next GC.
  object->clear_has_active_finalizer();
  return BOOL(result);
}

PRIMITIVE(gc_count) {
  return Smi::from(process->object_heap()->gc_count(NEW_SPACE_GC));
}

PRIMITIVE(create_off_heap_byte_array) {
  ARGS(int, length);
  if (length < 0) FAIL(NEGATIVE_ARGUMENT);

  AllocationManager allocation(process);
  uint8* buffer = allocation.alloc(length);
  if (buffer == null) FAIL(ALLOCATION_FAILED);

  ByteArray* result = process->object_heap()->allocate_proxy(length, buffer, true);
  if (result == null) FAIL(ALLOCATION_FAILED);
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
  if (!success) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

#ifdef TOIT_FREERTOS
#define STACK_ENCODING_BUFFER_SIZE (2*1024)
#else
#define STACK_ENCODING_BUFFER_SIZE (16*1024)
#endif

PRIMITIVE(encode_error) {
  ARGS(Object, type, Object, message);
  MallocedBuffer buffer(STACK_ENCODING_BUFFER_SIZE);
  if (!buffer.has_content()) FAIL(MALLOC_FAILED);
  ProgramOrientedEncoder encoder(process->program(), &buffer);
  process->scheduler_thread()->interpreter()->store_stack();
  bool success = encoder.encode_error(type, message, process->task()->stack());
  process->scheduler_thread()->interpreter()->load_stack();
  if (!success) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

PRIMITIVE(rebuild_hash_index) {
  ARGS(Object, o, Object, n);
  // Sometimes the array is too big, and is a large array.  In this case, use
  // the Toit implementation.
  if (!is_array(o) || !is_array(n)) FAIL(OUT_OF_RANGE);
  Array* old_array = Array::cast(o);
  Array* new_array = Array::cast(n);
  word index_mask = new_array->length() - 1;
  word length = old_array->length();
  for (word i = 0; i < length; i++) {
    Object* o = old_array->at(i);
    word hash_and_position;
    if (is_smi(o)) {
      hash_and_position = Smi::value(o);
    } else if (is_large_integer(o)) {
      hash_and_position = LargeInteger::cast(o)->value();
    } else {
      FAIL(INVALID_ARGUMENT);
    }
    word slot = hash_and_position & index_mask;
    word step = 1;
    while (new_array->at(slot) != 0) {
      slot = (slot + step) & index_mask;
      step++;
    }
    new_array->at_put(slot, Smi::from(hash_and_position));
  }

  return process->null_object();
}

PRIMITIVE(profiler_install) {
  ARGS(bool, profile_all_tasks);
  if (process->profiler() != null) FAIL(ALREADY_EXISTS);
  int result = process->install_profiler(profile_all_tasks ? -1 : process->task()->id());
  if (result == -1) FAIL(MALLOC_FAILED);
  return Smi::from(result);
}

PRIMITIVE(profiler_start) {
  Profiler* profiler = process->profiler();
  if (profiler == null) FAIL(ALREADY_CLOSED);
  if (profiler->is_active()) return process->false_object();
  profiler->start();
  // Tell the scheduler that a new process has an active profiler.
  VM::current()->scheduler()->activate_profiler(process);
  return process->true_object();
}

PRIMITIVE(profiler_stop) {
  Profiler* profiler = process->profiler();
  if (profiler == null) FAIL(ALREADY_CLOSED);
  if (!profiler->is_active()) return process->false_object();
  profiler->stop();
  // Tell the scheduler to deactivate profiling for the process.
  VM::current()->scheduler()->deactivate_profiler(process);
  return process->true_object();
}

PRIMITIVE(profiler_encode) {
  ARGS(String, title, int, cutoff);
  Profiler* profiler = process->profiler();
  if (profiler == null) FAIL(ALREADY_CLOSED);
  MallocedBuffer buffer(4096);
  ProgramOrientedEncoder encoder(process->program(), &buffer);
  bool success = encoder.encode_profile(profiler, title, cutoff);
  if (!success) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

PRIMITIVE(profiler_uninstall) {
  Profiler* profiler = process->profiler();
  if (profiler == null) FAIL(ALREADY_CLOSED);
  process->uninstall_profiler();
  return process->null_object();
}

PRIMITIVE(set_max_heap_size) {
  ARGS(word, max_bytes);
  process->set_max_heap_size(max_bytes);
  process->object_heap()->update_pending_limit();
  return process->null_object();
}

PRIMITIVE(get_real_time_clock) {
  Array* result = process->object_heap()->allocate_array(2, Smi::zero());
  if (result == null) FAIL(ALLOCATION_FAILED);

  struct timespec time{};
  if (!OS::get_real_time(&time)) FAIL(ERROR);

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
  if (sizeof(timespec::tv_sec) == sizeof(long) && (tv_sec < LONG_MIN || tv_sec > LONG_MAX)) FAIL(INVALID_ARGUMENT);
  if (tv_nsec < LONG_MIN || tv_nsec > LONG_MAX) FAIL(INVALID_ARGUMENT);
  struct timespec time = {
    .tv_sec = static_cast<long>(tv_sec),
    .tv_nsec = static_cast<long>(tv_nsec),
  };
  static_assert(sizeof(time.tv_nsec) == sizeof(long), "Unexpected size of timespec field");
  if (!OS::set_real_time(&time)) FAIL(ERROR);
#endif
  return Smi::zero();
}

PRIMITIVE(tune_memory_use) {
  ARGS(int, percent);
  if (!(0 <= percent && percent <= 100)) FAIL(OUT_OF_RANGE);
  GcMetadata::set_large_heap_heuristics(percent);
  return process->null_object();
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
  return process->true_object();
#else
  USE(limit);
  return process->false_object();
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

#if defined(TOIT_LINUX) || defined (TOIT_ESP32)
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
  FAIL(UNIMPLEMENTED);
#else
  ARGS(int, padding);
  if (padding < 0 || padding > 0x10000) FAIL(OUT_OF_RANGE);
#ifdef TOIT_LINUX
  if (heap_caps_iterate_tagged_memory_areas == null) {
    // This always happens on the server unless we are running with
    // cmpctmalloc (using LD_PRELOAD), which supports iterating the heap in
    // this way.
    return process->null_object();
  }
#endif

#if defined(TOIT_LINUX) || defined (TOIT_ESP32)
  const char* description = "Heap usage report";

  uword size = get_heap_dump_size(description);

  ByteArray* result = process->allocate_byte_array(size + padding);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  uint8* contents = bytes.address();

  word actual_size = heap_dump_to_byte_array(description, contents, size + padding);
  if (actual_size < 0) {
    // Due to other threads allocating and freeing we may not succeed in creating
    // a heap layout dump, in which case we return null.
    return process->null_object();
  }

  // Fill up with ubjson no-ops.
  memset(contents + actual_size, 'N', size + padding - actual_size);

  return result;
#else
  return process->null_object();
#endif

#endif // def TOIT_CMPCTMALLOC
}

PRIMITIVE(serial_print_heap_report) {
#ifdef TOIT_CMPCTMALLOC
  ARGS(cstring, marker, int, max_pages);
  OS::heap_summary_report(max_pages, marker, process);
#endif // def TOIT_CMPCTMALLOC
  return process->null_object();
}

PRIMITIVE(get_env) {
#ifdef TOIT_FREERTOS
  // FreeRTOS supports environment variables, but we prefer not to expose them.
  FAIL(UNIMPLEMENTED);
#else
  ARGS(cstring, key);
  char* result = OS::getenv(key);
  if (result == null) return process->null_object();
  Object* string_or_error = process->allocate_string_or_error(result, strlen(result));
  free(result);
  return string_or_error;
#endif
}

PRIMITIVE(set_env) {
#ifdef TOIT_FREERTOS
  // FreeRTOS supports environment variables, but we prefer not to expose them.
  FAIL(UNIMPLEMENTED);
#else
  ARGS(cstring, key, cstring, value);
  if (value) {
    OS::setenv(key, value);
  } else {
    OS::unsetenv(key);
  }
  return process->null_object();
#endif
}

PRIMITIVE(literal_index) {
  ARGS(Object, o);
  auto null_object = process->null_object();
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

#ifdef TOIT_ESP32
static spi_flash_mmap_handle_t firmware_mmap_handle;
static bool firmware_is_mapped = false;
#endif

PRIMITIVE(firmware_map) {
  ARGS(Object, bytes);
#ifndef TOIT_ESP32
  return bytes;
#else
  if (bytes != process->null_object()) {
    // If we're passed non-null bytes, we use that as the
    // firmware bits.
    return bytes;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (firmware_is_mapped) {
    // We unmap to allow the next attempt to get the current
    // system image to succeed.
    spi_flash_munmap(firmware_mmap_handle);
    firmware_is_mapped = false;
    FAIL(QUOTA_EXCEEDED);  // Quota is 1.
  }

  const esp_partition_t* current_partition = esp_ota_get_running_partition();
  if (current_partition == null) FAIL(ERROR);

  // On the ESP32, it is beneficial to map the partition in as instructions
  // because there is a larger virtual address space for that.
  esp_partition_mmap_memory_t memory = ESP_PARTITION_MMAP_DATA;
#if defined(CONFIG_IDF_TARGET_ESP32)
  memory = ESP_PARTITION_MMAP_INST;
#endif

  const void* mapped_to = null;
  esp_err_t err = esp_partition_mmap(
      current_partition,
      0,  // Offset from start of partition.
      current_partition->size,
      memory,
      &mapped_to,
      &firmware_mmap_handle);
  if (err == ESP_ERR_NO_MEM) {
    FAIL(MALLOC_FAILED);
  } else if (err != ESP_OK) {
    FAIL(ERROR);
  }

  firmware_is_mapped = true;
  proxy->set_external_address(
      current_partition->size,
      const_cast<uint8*>(reinterpret_cast<const uint8*>(mapped_to)));
  return proxy;
#endif
}

PRIMITIVE(firmware_unmap) {
#ifdef TOIT_ESP32
  ARGS(ByteArray, proxy);
  if (!firmware_is_mapped) process->null_object();
  spi_flash_munmap(firmware_mmap_handle);
  firmware_is_mapped = false;
  proxy->clear_external_address();
#endif
  return process->null_object();
}

PRIMITIVE(firmware_mapping_at) {
  ARGS(Instance, receiver, int, index);
  word offset = Smi::value(receiver->at(1));
  word size = Smi::value(receiver->at(2));
  if (index < 0 || index >= size) FAIL(OUT_OF_BOUNDS);

  Blob input;
  if (!receiver->at(0)->byte_content(process->program(), &input, STRINGS_OR_BYTE_ARRAYS)) {
    FAIL(WRONG_OBJECT_TYPE);
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
  ARGS(Instance, receiver, word, from, word, to, ByteArray, into, word, index);
  if (index < 0) FAIL(OUT_OF_BOUNDS);
  word offset = Smi::value(receiver->at(1));
  word size = Smi::value(receiver->at(2));
  if (!Utils::is_aligned(from + offset, sizeof(uint32)) ||
      !Utils::is_aligned(to + offset, sizeof(uint32))) FAIL(INVALID_ARGUMENT);
  if (from > to || from < 0 || to > size) FAIL(OUT_OF_BOUNDS);

  Blob input;
  if (!receiver->at(0)->byte_content(process->program(), &input, STRINGS_OR_BYTE_ARRAYS)) {
    FAIL(WRONG_OBJECT_TYPE);
  }

  // Firmware is potentially mapped into memory that only allow word
  // access. We use an IRAM safe memcpy alternative that guarantees
  // always reading whole words to avoid issues with this.
  ByteArray::Bytes output(into);
  word bytes = to - from;
  if (index + bytes > output.length()) FAIL(OUT_OF_BOUNDS);
  iram_safe_memcpy(output.address() + index, input.address() + from + offset, bytes);
  return Smi::from(index + bytes);
}

#ifdef TOIT_ESP32
PRIMITIVE(rtc_user_bytes) {
  uint8* rtc_memory = RtcMemory::user_data_address();
  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      RtcMemory::RTC_USER_DATA_SIZE, rtc_memory, false, false);
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}
#else
PRIMITIVE(rtc_user_bytes) {
  static uint8 rtc_memory[4096];
  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      sizeof(rtc_memory), rtc_memory, false, false);
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}
#endif

} // namespace toit

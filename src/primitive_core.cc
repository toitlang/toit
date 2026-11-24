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

#include "dtoa.h"
#include "encoder.h"
#include "entropy_mixer.h"
#include "flags.h"
#include "heap.h"
#include "heap_report.h"
#include "hw_perf.h"
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
#elif defined(TOIT_EC618)
#include "rtc_memory_ec618.h"
#include "embedded_data.h"
extern "C" {
  #include "mem_map.h"
}
#endif

#if !defined(RAW) && !defined(TOIT_FREERTOS)
#include "compiler/compiler.h"
#endif

#include <math.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <cinttypes>
#include <climits>
#include <ctype.h>
#include <errno.h>
#include <sys/time.h>

#ifdef TOIT_WINDOWS
#include <windows.h>
#include <tchar.h>
#include "error_win.h"
#endif

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

#include <windows.h>
#include <vector>

static void replace_line_endings(const uint8* bytes, size_t length, std::vector<uint8>& buffer) {
  for (size_t i = 0; i < length; ++i) {
    if (bytes[i] == '\n' && (i == 0 || bytes[i - 1] != '\r')) {
      buffer.push_back('\r'); // Add '\r' before '\n' if not already preceded by it.
    }
    buffer.push_back(bytes[i]);
  }
}

static Object* write_on_std(const uint8* bytes, size_t length, bool is_stdout, bool newline, Process* process) {
  HANDLE console = GetStdHandle(is_stdout ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
  if (console == INVALID_HANDLE_VALUE) {
    return Primitive::os_error(GetLastError(), process);
  }

  DWORD written;
  DWORD mode;

  // Prepare buffer with replaced line endings.
  std::vector<uint8> buffer;
  replace_line_endings(bytes, length, buffer);

  // Check if the handle is a console handle.
  if (GetConsoleMode(console, &mode)) {
    // Write to the console.
    WriteConsoleA(console, buffer.data(), (DWORD)buffer.size(), &written, NULL);

    if (newline) {
      WriteConsoleA(console, "\r\n", 2, &written, NULL);
    }
  } else {
    // Handle redirection case.
    WriteFile(console, buffer.data(), (DWORD)buffer.size(), &written, NULL);

    if (newline) {
      WriteFile(console, "\r\n", 2, &written, NULL);
    }
  }

  return process->null_object();
}

#elif (_POSIX_C_SOURCE >= 199309L || _BSD_SOURCE) && defined(_POSIX_THREAD_SAFE_FUNCTIONS)

static Object* write_on_std(const uint8* bytes, size_t length, bool is_stdout, bool newline, Process* process) {
  FILE* stream = is_stdout ? stdout : stderr;
  flockfile(stream);
  fwrite_unlocked(bytes, 1, length, stream);
  if (newline) {
    fputc_unlocked('\n', stream);
  }
  fflush_unlocked(stream);
  funlockfile(stream);
  return process->null_object();
}

#else

static Object* write_on_std(const uint8* bytes, size_t length, bool is_stdout, bool newline, Process* process) {
  FILE* stream = is_stdout ? stdout : stderr;
  fwrite(bytes, 1, length, stream);
  if (newline) {
    fputc('\n', stream);
  }
  fflush(stream);
  return process->null_object();
}

#endif

// These primitives are deliberately synchronous. They are shared by print_
// and io.stdout/io.stderr and retain the platform's printf-like behavior.
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
  if (decoder.malformed_input()) {
    // Not produced by the encoder: free all of it (see task_receive_message).
    decoder.remove_disposing_finalizers();
    process->clear_main_arguments();
    MessageDecoder::deallocate(arguments);
    FAIL(INVALID_ARGUMENT);
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
  if (decoder.malformed_input()) {
    // Not produced by the encoder: free all of it (see task_receive_message).
    decoder.remove_disposing_finalizers();
    process->clear_spawn_arguments();
    MessageDecoder::deallocate(arguments);
    FAIL(INVALID_ARGUMENT);
  }

  process->clear_spawn_arguments();
  free(arguments);
  decoder.register_external_allocations();
  return decoded;
}

PRIMITIVE(spawn_method) {
  Method method = process->spawn_method();
  if (process->program()->is_format2()) {
    // Format 2: the method index (the spawn method points at its entry).
    if (!method.is_valid()) return Smi::from(-1);
    word entry = process->program()->absolute_bci_from_bcp(method.header_bcp());
    return Smi::from(process->group()->v2_methods()->index_of_entry(entry));
  }
  int id = method.is_valid()
      ? process->program()->absolute_bci_from_bcp(method.header_bcp())
      : -1;
  return Smi::from(id);
}

PRIMITIVE(spawn) {
  ARGS(int, priority, Object, entry, Object, arguments)
  if (priority != -1 && (priority < 0 || priority > 0xff)) FAIL(OUT_OF_RANGE);
  if (!is_smi(entry)) FAIL(WRONG_OBJECT_TYPE);

  // The method id comes from a 'Lambda_' object, which the program can
  // modify. It must be a legal lambda method of the program.
  word method_id = Smi::value(entry);
  Method method = Method::invalid();
  if (process->program()->is_format2()) {
    // Format 2: an index into the method table. The new process' spawn
    // method points at the method's entry.
    const V2MethodTable* table = process->group()->v2_methods();
    if (!table->is_valid(method_id) || table->at(method_id).kind != V2_KIND_LAMBDA) {
      FAIL(INVALID_ARGUMENT);
    }
    method = Method(process->program()->bytecodes, table->at(method_id).entry);
  } else {
#ifdef TOIT_NO_CXX_INTERPRETER
    FAIL(INVALID_ARGUMENT);  // Unreachable: no format-1 process groups.
#endif
    if (!process->group()->method_entries()->is_entry(method_id)) FAIL(INVALID_ARGUMENT);
    method = Method(process->program()->bytecodes, method_id);
    if (!method.is_lambda_method()) FAIL(INVALID_ARGUMENT);
  }

  InitialMemoryManager initial_memory_manager;
  if (!initial_memory_manager.allocate()) FAIL(ALLOCATION_FAILED);

  word size = 0;
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

  // The child is created in the same process group, so it inherits the
  // group's policy. The scheduler enforces the process quota of the policy.
  int pid = VM::current()->scheduler()->spawn(
      process->program(),
      process->group(),
      priority,
      method,
      &encoder,                  // Takes over encoder.
      &initial_memory_manager);  // Takes over initial memory.
  if (pid == Scheduler::QUOTA_EXCEEDED_PROCESS_ID) {
    FAIL(QUOTA_EXCEEDED);
  }
  if (pid == Scheduler::INVALID_PROCESS_ID) {
    FAIL(MALLOC_FAILED);
  }

  return Smi::from(pid);
}

PRIMITIVE(get_generic_resource_group) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // The group lives until the process exits, so a sandboxed program calling
  // this in a loop would take VM memory without bound.
  if (!process->may_add_permanent_resource_group()) FAIL(QUOTA_EXCEEDED);
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

PRIMITIVE(process_system_id) {
  return Smi::from(VM::current()->scheduler()->boot_process_id());
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
  bool valid = Utils::is_valid_utf_8(bytes.address() + start, end - start);
  return BOOL(valid);
}

PRIMITIVE(byte_array_convert_to_string) {
  ARGS(Blob, bytes, int, start, int, end);
  if (!(0 <= start && start <= end && end <= bytes.length())) FAIL(OUT_OF_BOUNDS);
  bool valid = Utils::is_valid_utf_8(bytes.address() + start, end - start);
  if (!valid) FAIL(ILLEGAL_UTF_8);
  return process->allocate_string_or_error(char_cast(bytes.address()) + start, end - start);
}

PRIMITIVE(blob_index_of) {
  ARGS(Blob, bytes, int, byte, word, from, word, to);
  if (!(0 <= from && from <= to && to <= bytes.length())) FAIL(OUT_OF_BOUNDS);
#if defined(__x86_64__) && !defined(__SANITIZE_THREAD__) && !defined(__SANITIZE_ADDRESS__) && !defined(TOIT_ASAN)
  const uint8* address = bytes.address();
  // Algorithm from https://github.com/erikcorry/struhchuh.
  // Search for "*" using only aligned SSE2 128 bit loads. This may load data
  // either side of the string, but can never cause a fault because the loads are
  // in 128 bit sections also covered by the string and the fault hardware works
  // at a higher granularity.  Threadsanitizer doesn't understand this and reports
  // use-after-frees. AddressSanitizer also rejects loads outside the allocation;
  // sanitizer builds use the bounded memchr path below.
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
      // This 'if' will fail if we are dealing with a List so large
      // that it has arraylets.
      Object* array_object = list->at(0);
      if (is_array(array_object)) {
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
  uint64 checksum = static_cast<uint64>(accumulator);
  for (word i = from; i < to; i++) {
    uint8 byte = data.address()[i];
    uint64 index = checksum;
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
    checksum = (big_endian ? checksum << 8 : checksum >> 8) ^ static_cast<uint64>(entry);
  }
  if ((width & 63) != 0) {
    // If width is less than 64 we have to mask the result.  For the little
    // endian case (width == 0) we don't need to mask.
    uint64 mask = 1;
    mask = (mask << (width & 63)) - 1;
    checksum &= mask;
  }
  return Primitive::integer(static_cast<int64>(checksum), process);
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
  if (dest_index < 0 || to - from > dest.length() - dest_index) FAIL(OUT_OF_BOUNDS);
  // The source and the destination may be the same byte array.
  memmove(&dest.address()[dest_index], &source_bytes.address()[from], to - from);
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
  // A negative width becomes a large unsigned one (`width - 1` in int
  // overflowed for INT_MIN).
  unsigned unsigned_width = width;
  uword unsigned_offset = offset;
  uword length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width == 0 || unsigned_width > 8 || unsigned_offset + unsigned_width > length) {
    FAIL(OUT_OF_BOUNDS);
  }
  uword width_minus_1 = unsigned_width - 1;
  int64 value = static_cast<int8>(source.address()[offset]);  // Sign extend.
  for (uword i = 1; i <= width_minus_1; i++) {
    value = Utils::wrapping_shift_left(value, 8);
    value |= source.address()[offset + i];
  }
  return Primitive::integer(value, process);
}

PRIMITIVE(read_int_little_endian) {
  ARGS(Object, unused, Blob, source, int, width, word, offset);
  USE(unused);
  // A negative width becomes a large unsigned one (`width - 1` in int
  // overflowed for INT_MIN).
  unsigned unsigned_width = width;
  uword unsigned_offset = offset;
  uword length = source.length();
  // We don't need to check for <0 on unsigned values.  Can't have integer
  // overflow when they are both constrained in size (assuming the byte
  // array can't be close to 4Gbytes large).
  if (unsigned_offset > length || unsigned_width == 0 || unsigned_width > 8 || unsigned_offset + unsigned_width > length) {
    FAIL(OUT_OF_BOUNDS);
  }
  uword width_minus_1 = unsigned_width - 1;
  int64 value = static_cast<int8>(source.address()[offset + width_minus_1]);  // Sign extend.
  for (uword i = width_minus_1; i != 0; i--) {
    value = Utils::wrapping_shift_left(value, 8);
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
  return Primitive::integer(Utils::wrapping_add(receiver, other), process);
}

PRIMITIVE(smi_subtract) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    // Smis have fewer bits than words, so the difference fits a word.
    return Primitive::integer(static_cast<int64>(receiver) - Smi::value(arg), process);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  int64 other = LargeInteger::cast(arg)->value();
  return Primitive::integer(Utils::wrapping_sub(receiver, other), process);
}

PRIMITIVE(smi_multiply) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    // The tagged smi is `other << 1`, so the product is the tagged result.
    // Using it avoids shifting a negative value.
    word tagged_other = reinterpret_cast<word>(arg);
    word result;
    if (__builtin_mul_overflow(receiver, tagged_other, &result)) goto overflow;
    Smi* r = reinterpret_cast<Smi*>(result);
    ASSERT(r == Smi::from(result >> 1));
    return r;
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  overflow:
  int64 other = is_smi(arg) ? (int64) Smi::value(arg) : LargeInteger::cast(arg)->value();
  return Primitive::integer(Utils::wrapping_mul(receiver, other), process);
}

PRIMITIVE(smi_divide) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    // MIN_SMI / -1 is not a smi; Primitive::integer promotes it.
    return Primitive::integer((int64) receiver / other, process);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  int64 other = LargeInteger::cast(arg)->value();
  if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
  return Primitive::integer((int64) receiver / other, process);
}

PRIMITIVE(smi_mod) {
  ARGS(word, receiver, Object, arg);
  if (is_smi(arg)) {
    word other = Smi::value(arg);
    if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
    return Smi::from(receiver % other);
  }
  if (!is_large_integer(arg)) FAIL(WRONG_OBJECT_TYPE);
  int64 other = LargeInteger::cast(arg)->value();
  if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
  return Primitive::integer((int64) receiver % other, process);
}

static uint64 format_quotient(uint64 value, int base) {
  // Constant divisors let embedded targets use shifts or reciprocal multiplication.
  switch (base) {
    case 2: return value / 2;
    case 8: return value / 8;
    case 10: return value / 10;
    case 16: return value / 16;
    default: return value / base;
  }
}

static Object* format_integer(Process* process, int64 value, int base, bool unsigned_format) {
  uint64 remaining;
  bool negative = value < 0 && !unsigned_format;
  if (value < 0) {
    uint64 complement = static_cast<uint64>(-(value + 1));
    remaining = negative ? complement + 1 : static_cast<uint64>(UINT64_MAX) - complement;
  } else {
    remaining = static_cast<uint64>(value);
  }
  // A 64-bit magnitude in base two and an optional minus sign.
  uint8 buffer[65];
  int start = sizeof(buffer);
  while (true) {
    uint64 quotient = format_quotient(remaining, base);
    int digit = static_cast<int>(remaining - quotient * base);
    remaining = quotient;
    start--;
    buffer[start] = digit < 10 ? '0' + digit : 'a' + (digit - 10);
    if (remaining == 0) break;
  }
  if (negative) {
    start--;
    buffer[start] = '-';
  }
  Object* result = process->allocate_string_or_error(reinterpret_cast<const char*>(buffer + start), sizeof(buffer) - start);
  return result;
}

PRIMITIVE(int64_to_string) {
  ARGS(int64, value, int, base);
  if (!(2 <= base && base <= 36)) FAIL(OUT_OF_RANGE);
  return format_integer(process, value, base, false);
}

PRIMITIVE(uint64_to_string) {
  ARGS(int64, value);
  return format_integer(process, value, 10, true);
}

PRIMITIVE(large_integer_add) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result = Utils::wrapping_add(result, Smi::value(arg));
  else if (is_large_integer(arg)) result = Utils::wrapping_add(result, LargeInteger::cast(arg)->value());
  else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_subtract) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result = Utils::wrapping_sub(result, Smi::value(arg));
  else if (is_large_integer(arg)) result = Utils::wrapping_sub(result, LargeInteger::cast(arg)->value());
  else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_multiply) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  if (is_smi(arg)) result = Utils::wrapping_mul(result, Smi::value(arg));
  else if (is_large_integer(arg)) result = Utils::wrapping_mul(result, LargeInteger::cast(arg)->value());
  else FAIL(WRONG_OBJECT_TYPE);
  return Primitive::integer(result, process);
}

// Ints wrap around. Dividing int.MIN by -1 traps on x86 (SIGFPE, taking
// down the whole VM), so division by -1 is handled separately.
static int64 wrapping_negate(int64 value) {
  return value == INT64_MIN ? value : -value;
}

PRIMITIVE(large_integer_divide) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  int64 divisor;
  if (is_smi(arg)) {
    divisor = Smi::value(arg);
  } else if (is_large_integer(arg)) {
    divisor = LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
  if (divisor == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
  result = (divisor == -1) ? wrapping_negate(result) : result / divisor;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_mod) {
  ARGS(LargeInteger, receiver, Object, arg);
  int64 result = receiver->value();
  int64 divisor;
  if (is_smi(arg)) {
    divisor = Smi::value(arg);
  } else if (is_large_integer(arg)) {
    divisor = LargeInteger::cast(arg)->value();
  } else FAIL(WRONG_OBJECT_TYPE);
  if (divisor == 0) return Primitive::mark_as_error(process->program()->division_by_zero());
  result = (divisor == -1) ? static_cast<int64>(0) : result % divisor;
  return Primitive::integer(result, process);
}

PRIMITIVE(large_integer_unary_minus) {
  ARGS(LargeInteger, receiver);
  return Primitive::integer(Utils::wrapping_negate(receiver->value()), process);
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
  return Primitive::integer(Utils::wrapping_shift_left(receiver->value(), number_of_bits), process);
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

static int64 decimal_round_factor(int precision) {
  if (precision < 0 || precision > 15) return 0;
  int64 factor = 1;
  for (int i = 0; i < precision; i++) {
    factor *= 10;
  }
  return factor;
}

PRIMITIVE(float_round) {
  ARGS(double, receiver, int, precision);
  int64 factor = decimal_round_factor(precision);
  if (factor == 0) FAIL(INVALID_ARGUMENT);
  if (isnan(receiver)) FAIL(OUT_OF_RANGE);
  // Binary64 values of either sign with magnitude at least 2^52 are already integral.
  if (receiver >= 4503599627370496.0 || receiver <= -4503599627370496.0) return _raw_receiver;
  return Primitive::allocate_double(round(receiver * factor) / factor, process);
}

static bool parse_short_decimal(const uint8* input, word length, int64* value) {
  bool negative = input[0] == '-';
  word first = negative ? 1 : 0;
  if (first == length) return false;
  int64 magnitude = 0;
  for (word index = first; index < length; index++) {
    uint8 c = input[index];
    if ('0' <= c && c <= '9') {
      magnitude = magnitude * 10 + (c - '0');
    } else if (c == '_') {
      if (index == first || index == length - 1) return false;
    } else {
      return false;
    }
  }
  *value = negative ? -magnitude : magnitude;
  return true;
}

PRIMITIVE(int_parse) {
  ARGS(Blob, input, word, from, word, to, int, block_arg_dont_use_this);
  if (!(0 <= from && from < to && to <= input.length())) FAIL(OUT_OF_RANGE);
  // Longer inputs use the Toit parser. Eighteen decimal digits fit in int64.
  if (to - from > 18) FAIL(OUT_OF_RANGE);
  int64 value = 0;
  bool valid = parse_short_decimal(input.address() + from, to - from, &value);
  if (!valid) FAIL(INVALID_ARGUMENT);
  Object* parsed = Primitive::integer(value, process);
  return parsed;
}

static bool parse_float_buffer(const uint8* bytes, word length, double* value) {
  const char* start = reinterpret_cast<const char*>(bytes);
  char* end;
  *value = strtod(start, &end);
  return end == start + length;
}

PRIMITIVE(float_parse) {
  ARGS(Blob, input, word, from, word, to, int, block_arg_dont_use_this);
  if (!(0 <= from && from < to && to <= input.length())) FAIL(OUT_OF_RANGE);
  bool terminated = is_string(_raw_input) && to == input.length();
  const uint8* bytes = input.address() + from;
  word length = to - from;
  // strtod skips leading whitespace, but float.parse rejects it.
  if (isspace(bytes[0])) {
    FAIL(ERROR);
  }
  double result;
  bool parsed;
  if (terminated) {
    parsed = parse_float_buffer(bytes, length, &result);
  } else {
    uint8* copy = static_cast<uint8*>(malloc(static_cast<size_t>(length) + 1));
    if (copy == null) {
      FAIL(ALLOCATION_FAILED);
    }
    memcpy(copy, bytes, length);
    copy[length] = 0;
    parsed = parse_float_buffer(copy, length, &result);
    free(copy);
  }
  if (!parsed) FAIL(ERROR);
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

// Calendar computations for time_info. Dates are in the proleptic Gregorian
// calendar and, like POSIX time_t, timestamps ignore leap seconds.

static const int64 SECONDS_PER_DAY = 24 * 60 * 60;

static int64 floor_div(int64 a, int64 b) {
  ASSERT(b > 0);
  int64 q = a / b;
  return (a % b < 0) ? q - 1 : q;
}

// The remainder of floor_div, in [0, b).
static int64 floor_mod(int64 a, int64 b) {
  ASSERT(b > 0);
  int64 r = a % b;
  return (r < 0) ? r + b : r;
}

static bool is_leap_year(int64 year) {
  return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

// The number of days from 1970-01-01 to the given date (month in 1-12).
// This is 'days_from_civil' of Howard Hinnant's "chrono-Compatible Low-Level
// Date Algorithms" (public domain).
// The computation uses years that start on March 1st, so that the leap day is
// the last day of the year, and 400-year eras of 146097 days.
static int64 days_from_civil(int64 year, int month, int day) {
  year -= month <= 2;
  int64 era = floor_div(year, 400);
  // In [0, 399].
  int64 year_of_era = year - era * 400;
  // In [0, 365], counted from March 1st.
  int64 day_of_year = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
  // In [0, 146096].
  int64 day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
  // 719468 is the number of days from 0000-03-01 to 1970-01-01.
  return era * 146097 + day_of_era - 719468;
}

// 0 is Sunday, like tm_wday. 1970-01-01 was a Thursday.
static int weekday_from_days(int64 days) {
  return static_cast<int>(days - floor_div(days + 4, 7) * 7 + 4);
}

struct TimeFields {
  int64 year;
  int month;    // 0-11, like tm_mon.
  int day;      // 1-31.
  int hour;
  int minute;
  int second;   // Normally 0-59, but the C library may report a leap second.
  int weekday;  // 0-6, Sunday is 0.
  int yearday;  // 0-365.
  bool is_dst;
};

// Computes the UTC fields of the given timestamp without calling the C
// library. This is exact for every int64, unlike gmtime_s on Windows which
// rejects all times before 1970.
// This is 'civil_from_days' of Howard Hinnant's algorithms.
static void utc_fields(int64 timestamp, TimeFields* fields) {
  int64 days = floor_div(timestamp, SECONDS_PER_DAY);
  // Not `timestamp - days * SECONDS_PER_DAY`: near INT64_MIN the start of
  // the day is below INT64_MIN, and the product overflows.
  int seconds_of_day = static_cast<int>(floor_mod(timestamp, SECONDS_PER_DAY));
  // Days since 0000-03-01.
  int64 z = days + 719468;
  int64 era = floor_div(z, 146097);
  // In [0, 146096].
  int64 day_of_era = z - era * 146097;
  // In [0, 399].
  int64 year_of_era =
      (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
  // In [0, 365], counted from March 1st.
  int64 day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
  // In [0, 11], 0 is March.
  int64 shifted_month = (5 * day_of_year + 2) / 153;
  // In [0, 11], 0 is January.
  int month = static_cast<int>(shifted_month < 10 ? shifted_month + 2 : shifted_month - 10);
  int64 year = year_of_era + era * 400 + (month <= 1);
  fields->year = year;
  fields->month = month;
  fields->day = static_cast<int>(day_of_year - (153 * shifted_month + 2) / 5 + 1);
  fields->hour = seconds_of_day / 3600;
  fields->minute = (seconds_of_day / 60) % 60;
  fields->second = seconds_of_day % 60;
  fields->weekday = weekday_from_days(days);
  fields->yearday = static_cast<int>(days - days_from_civil(year, 1, 1));
  fields->is_dst = false;
}

// Converts with the C library's localtime. Returns false if the C library
// can't convert the timestamp.
static bool os_localtime(int64 timestamp, struct tm* result) {
  memset(result, 0, sizeof(*result));
  time_t t = static_cast<time_t>(timestamp);
  if (static_cast<int64>(t) != timestamp) return false;  // A 32-bit time_t.
#ifdef TOIT_WINDOWS
  // The CRT's localtime_s fails with EINVAL for times before 1970 and after
  // 3000-12-31T23:59:59Z (_MAX__TIME64_T). Don't hand them to it.
  const int64 MAX_WINDOWS_TIME = 32535215999LL;
  if (timestamp < 0 || timestamp > MAX_WINDOWS_TIME) return false;
  return localtime_s(result, &t) == 0;
#else
  return localtime_r(&t, result) != null;
#endif
}

// Returns the year in [first, first + 27] that has the same calendar as the
// given year: it is a leap year if the given year is, and it starts on the
// same weekday. The range must not contain a year divisible by 100, so that
// it repeats every 28 years and contains all 14 calendars.
static int equivalent_year(int64 year, int first) {
  bool is_leap = is_leap_year(year);
  int weekday = weekday_from_days(days_from_civil(year, 1, 1));
  for (int candidate = first; candidate < first + 28; candidate++) {
    if (is_leap_year(candidate) == is_leap &&
        weekday_from_days(days_from_civil(candidate, 1, 1)) == weekday) {
      return candidate;
    }
  }
  UNREACHABLE();
}

// Computes the local fields of the given timestamp.
// The C library does this whenever it can. Otherwise (on Windows for times
// before 1970 or after the year 3000, or with a 32-bit time_t) the timestamp
// is moved by whole days into an equivalent year (same leap-year status and
// weekdays) that the C library handles: 1971-1998 for earlier times,
// 2010-2037 for later ones. The UTC offset and daylight-saving status that the
// C library reports for the moved time are then applied to the original
// timestamp.
// The Windows C library has no historical zone data: it applies the rules of
// the zone (from the TZ variable or the system settings) to every year, so
// the result is what it would compute if it accepted the timestamp.
// A C library with historical data (only used here with a 32-bit time_t)
// applies the rules of the equivalent year instead of the historical ones.
// The equivalent years are the closest to the range of the C library, which
// keeps the results continuous at its limits.
// Returns false if the timestamp is out of range.
static bool local_fields(int64 timestamp, TimeFields* fields) {
  struct tm tm;
  if (os_localtime(timestamp, &tm)) {
    fields->year = static_cast<int64>(tm.tm_year) + 1900;
    fields->month = tm.tm_mon;
    fields->day = tm.tm_mday;
    fields->hour = tm.tm_hour;
    fields->minute = tm.tm_min;
    fields->second = tm.tm_sec;
    fields->weekday = tm.tm_wday;
    fields->yearday = tm.tm_yday;
    // When the information isn't available we just say false for daylight saving.
    fields->is_dst = tm.tm_isdst > 0;
    return true;
  }
  TimeFields utc;
  utc_fields(timestamp, &utc);
  // Avoid overflows in the shift below. The caller rejects these years anyway.
  if (!Smi::is_valid32(utc.year)) return false;
  int equivalent = equivalent_year(utc.year, utc.year < 2000 ? 1971 : 2010);
  int64 shift_days = days_from_civil(equivalent, 1, 1) - days_from_civil(utc.year, 1, 1);
  int64 moved = timestamp + shift_days * SECONDS_PER_DAY;
  if (!os_localtime(moved, &tm)) return false;
  int64 local_moved_days = days_from_civil(static_cast<int64>(tm.tm_year) + 1900, tm.tm_mon + 1, tm.tm_mday);
  int64 local_moved =
      local_moved_days * SECONDS_PER_DAY + tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec;
  int64 offset = local_moved - moved;
  utc_fields(timestamp + offset, fields);
  fields->is_dst = tm.tm_isdst > 0;
  return true;
}

PRIMITIVE(time_info) {
  ARGS(int64, timestamp, bool, is_utc)
  TimeFields fields;
  if (is_utc) {
    utc_fields(timestamp, &fields);
  } else if (!local_fields(timestamp, &fields)) {
    FAIL(OUT_OF_RANGE);
  }
  // Keep the year a small integer on all platforms.
  if (!Smi::is_valid32(fields.year)) FAIL(OUT_OF_RANGE);
  Array* result = process->object_heap()->allocate_array(9, Smi::zero());
  if (result == null) FAIL(ALLOCATION_FAILED);
  result->at_put(0, Smi::from(fields.second));
  result->at_put(1, Smi::from(fields.minute));
  result->at_put(2, Smi::from(fields.hour));
  result->at_put(3, Smi::from(fields.day));
  result->at_put(4, Smi::from(fields.month));
  result->at_put(5, Smi::from(static_cast<word>(fields.year)));
  result->at_put(6, Smi::from(fields.weekday));
  result->at_put(7, Smi::from(fields.yearday));
  result->at_put(8, BOOL(fields.is_dst));
  return result;
}

PRIMITIVE(seconds_since_epoch_local) {
  ARGS(int32, year, int32, month, int32, day, int32, hour, int32, min, int32, sec, Object, daylight_saving_is_active)
  struct tm decomposed;
  memset(&decomposed, 0, sizeof(decomposed));
  // Preserve the wrapped 32-bit tm_year even at the lower limit of the input range.
  int64 tm_year = static_cast<int64>(year) - 1900;
  if (tm_year < INT32_MIN) tm_year += 0x100000000LL;
  decomposed.tm_year = static_cast<int32>(tm_year);
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
#ifdef TOIT_LINUX
  // A successful mktime can set errno while reading the timezone. It sets
  // the weekday even when the timestamp itself is -1.
  decomposed.tm_wday = -1;
  int64 result = mktime(&decomposed);
  bool failed = result == -1 && decomposed.tm_wday == -1;
#else
  errno = 0;
  int64 result = mktime(&decomposed);
  bool failed = result == -1 && errno != 0;
#endif
  if (failed) {
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
  const uint8* p = bytes.address() + offset;
  const uint8* end = bytes.address() + bytes.length();
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
#if defined(TOIT_ASAN) || defined(__SANITIZE_ADDRESS__)
  // The word-sized loads below read the bytes before and after the blob in
  // the same aligned word. They can't fault, but AddressSanitizer rejects
  // them (an external byte array is a malloced block of any size), so
  // sanitizer builds count byte by byte.
  for (word i = 0; i < len; i++) {
    if ((address[i] & 0xc0) != 0x80) count++;
  }
  return Smi::from(count);
#endif
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
  return format_integer(process, receiver, 10, false);
}

// Interpolation formats binary, octal and hexadecimal as unsigned 64-bit values.
PRIMITIVE(printf_style_int64_to_string) {
  ARGS(int64, receiver, int, base);
  if (base != 2 && base != 8 && base != 16) FAIL(INVALID_ARGUMENT);
  return format_integer(process, receiver, base, true);
}

// On success, returns the length excluding the terminator. If the result
// does not fit, returns an upper bound that includes room for a possible ".0".
static int format_fixed_double(char* buffer, int capacity, int precision, double value) {
  int written = snprintf(buffer, capacity, "%.*lf", precision, value);
  if (written < 0 || written > INT_MAX - 3) {
    return -1;
  }
  if (written >= capacity) return written + 2;
  for (int i = 0; i < written; i++) {
    char c = buffer[i];
    if (c == 'e' || c == 'E' || c == '.') {
      return written;
    }
  }
  if (capacity - written >= 3) {
    buffer[written] = '.';
    buffer[written + 1] = '0';
    buffer[written + 2] = '\0';
  }
  return written + 2;
}

static Object* copy_float_string(Process* process, const char* buffer, int length) {
  Object* result = process->allocate_string(buffer, length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}

static Object* fixed_double_to_string(Process* process, int precision, double value) {
  char stack_buffer[MAX_BUFFER_SIZE_DOUBLE_TO_SHORTEST];
  int length = format_fixed_double(stack_buffer, sizeof(stack_buffer), precision, value);
  if (length >= 0 && length < static_cast<int>(sizeof(stack_buffer))) {
    return copy_float_string(process, stack_buffer, length);
  }
  // A legacy snprintf may report truncation as -1. A finite binary64 in
  // the C locale needs at most a sign, 309 integer digits, a point, and
  // 64 fractional digits. Allow space for ".0" and the terminator as well.
  if (!Smi::is_valid(static_cast<int64>(length))) FAIL(MALLOC_FAILED);
  int capacity = length < 0 ? 1 + 309 + 1 + 64 + 3 : length + 1;
  char* buffer = static_cast<char*>(malloc(capacity));
  if (buffer == null) FAIL(MALLOC_FAILED);
  length = format_fixed_double(buffer, capacity, precision, value);
  if (length < 0 || length >= capacity) {
    free(buffer);
    FAIL(MALLOC_FAILED);
  }
  Object* result = copy_float_string(process, buffer, length);
  free(buffer);
  return result;
}

PRIMITIVE(float_to_string) {
  ARGS(double, receiver, Object, precision);
  int classification = fpclassify(receiver);
  if (classification == FP_NAN) return process->allocate_string_or_error("nan");
  bool is_negative = signbit(receiver);
  if (classification == FP_INFINITE) {
    if (is_negative) {
      return process->allocate_string_or_error("-inf");
    } else {
      return process->allocate_string_or_error("inf");
    }
  }
  if (precision == process->null_object()) {
    if (classification == FP_ZERO) {
      if (is_negative) {
        return process->allocate_string_or_error("-0.0");
      } else {
        return process->allocate_string_or_error("0.0");
      }
    }
    char stack_buffer[MAX_BUFFER_SIZE_DOUBLE_TO_SHORTEST];
    int length = double_to_shortest(receiver, stack_buffer, sizeof(stack_buffer));
    if (length < 0) FAIL(INVALID_ARGUMENT);
    return copy_float_string(process, stack_buffer, length);
  }
  if (is_large_integer(precision)) FAIL(OUT_OF_BOUNDS);
  if (!is_smi(precision)) FAIL(WRONG_OBJECT_TYPE);
  word prec = Smi::value(precision);
  if (prec < 0 || prec > 64) FAIL(OUT_OF_BOUNDS);
  return fixed_double_to_string(process, static_cast<int>(prec), receiver);
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

// The longest string a concatenation makes (the verified core's
// MAX_BLOB_LENGTH: 2^30 bytes on 32-bit, 2^62 on 64-bit). The lengths of
// the parts are checked against it before they are added: on 32-bit their
// sum wrapped (257 references to a 16 MB string), and the copy then wrote
// far past the string allocated for the wrapped sum.
static const word MAX_CONCATENATION_LENGTH = static_cast<word>(1) << (WORD_BIT_SIZE - 2);

static String* concat_strings(Process* process,
                              const uint8* bytes_a, word len_a,
                              const uint8* bytes_b, word len_b) {
  ASSERT(len_a <= MAX_CONCATENATION_LENGTH && len_b <= MAX_CONCATENATION_LENGTH - len_a);
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
  if (receiver_blob.length() > MAX_CONCATENATION_LENGTH ||
      other_blob.length() > MAX_CONCATENATION_LENGTH - receiver_blob.length()) {
    FAIL(OUT_OF_RANGE);
  }
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
    if (blob.length() > MAX_CONCATENATION_LENGTH - length) FAIL(OUT_OF_RANGE);
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

static bool fill_string_from_utf_16(const Blob* input, String* destination) {
  String::MutableBytes output(destination);
  word written = Utils::utf_16le_to_8(input->address(), input->length() / 2, output.address(), output.length());
  return written == output.length();
}

PRIMITIVE(utf_16_to_string) {
  ARGS(Blob, utf_16);
  if ((utf_16.length() & 1) != 0) FAIL(INVALID_ARGUMENT);
  if (utf_16.length() > 0x3fffffff) FAIL(OUT_OF_BOUNDS);

  word utf_8_length = Utils::utf_16le_to_8(utf_16.address(), utf_16.length() / 2, nullptr, 0);
  if (utf_8_length > Smi::MAX_SMI_VALUE) FAIL(OUT_OF_BOUNDS);
  String* result = process->allocate_string(utf_8_length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  bool filled = fill_string_from_utf_16(&utf_16, result);
  if (!filled) FAIL(INVALID_ARGUMENT);
  return result;
}

// The byte-array capacity is measured in bytes, the converter in UTF-16 units.
static word fill_utf_16(const Blob* input, ByteArray::Bytes* output) {
  if (reinterpret_cast<uword>(output->address()) % sizeof(uint16) != 0) return -1;
  return Utils::utf_8_to_16(input->address(), input->length(),
                            reinterpret_cast<uint16*>(output->address()), output->length() / static_cast<word>(sizeof(uint16)));
}

PRIMITIVE(string_to_utf_16) {
  ARGS(StringOrSlice, utf_8);
  if (utf_8.length() > 0xfffffff) FAIL(OUT_OF_BOUNDS);

  int utf_16_length = Utils::utf_8_to_16(
      utf_8.address(), utf_8.length(), static_cast<uint16*>(nullptr), 0);

  ByteArray* result = process->allocate_byte_array(utf_16_length << 1);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);

  word written = fill_utf_16(&utf_8, &bytes);
  if (written != utf_16_length) FAIL(INVALID_ARGUMENT);

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
  // Arrays on the program heap are shared and read-only.
  if (receiver->on_program_heap(process)) FAIL(PERMISSION_DENIED);
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
  // Arrays on the program heap are shared and read-only.
  if (dest->on_program_heap(process)) FAIL(PERMISSION_DENIED);
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
    // Objects on the program heap are shared and read-only.
    if (list->on_program_heap(process)) FAIL(PERMISSION_DENIED);
    if (list->class_id() == process->program()->list_class_id()) {
      Object* array_object;
      if (is_array(array_object = list->at(0))) {
        // Small array backing case.
        Array* array = Array::cast(array_object);
        Object* size_object = list->at(1);
        if (is_smi(size_object)) {
          word size = Smi::value(size_object);
          if (0 <= size && size < array->length() && !array->on_program_heap(process)) {
            list->at_put(1, Smi::from(size + 1));
            array->at_put(size, value);
            return process->null_object();
          }
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
  // Byte arrays on the program heap are shared and read-only.
  if (receiver->on_program_heap(process)) FAIL(PERMISSION_DENIED);
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
  return Primitive::integer(Utils::wrapping_shift_left(value, number_of_bits), process);
}

PRIMITIVE(task_new) {
  ARGS(Instance, code);
  Task* task = process->object_heap()->allocate_task();
  if (task == null) FAIL(ALLOCATION_FAILED);
  if (process->program()->is_format2()) {
    // Format 2 (v2::prim::task_new_step): the new task's stack holds the
    // code; the first transfer to it builds the entry frames.
    task->stack()->v2_initialize_new_task(code);
    return task;
  }
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
  if (process->program()->is_format2()) {
    return Interpreter::v2_task_transfer(process, to, detach_stack);
  }
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

  const PrimitivePolicy* policy = process->policy();
  // Sandboxed processes may only send the RPC and trace message types and
  // the non-reserved types. Their targets are checked by the scheduler.
  if (!policy->may_send_type(type)) FAIL(PERMISSION_DENIED);
  // Trace messages may only go to the system process.
  if (policy->restricts_messaging() && type == SYSTEM_TRACE && process_id >= 0 &&
      process_id != VM::current()->scheduler()->boot_process_id()) {
    FAIL(PERMISSION_DENIED);
  }

  const PolicyQuotas& quotas = policy->quotas();
  word size = 0;
  word total_size = 0;
  { MessageEncoder size_encoder(process, null);
    // Stop the size pass at the quota: a shared object is encoded once per
    // reference, so the work isn't bounded by the size of the object graph,
    // and a primitive can't be interrupted.
    size_encoder.set_max_total_size(quotas.max_message_bytes);
    if (!size_encoder.encode(array)) {
      if (size_encoder.over_limit()) FAIL(QUOTA_EXCEEDED);
      return size_encoder.create_error_object(process);
    }
    size = size_encoder.size();
    total_size = size_encoder.total_size();
  }
  if (quotas.max_message_bytes > 0 && total_size > quotas.max_message_bytes) FAIL(QUOTA_EXCEEDED);

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
  message->set_size(total_size);
  if (policy->restricts_messaging()) {
    message->set_restricted(quotas.max_mailbox_messages, quotas.max_mailbox_bytes);
  }

  // Takes over the SystemMessage.
  message_err_t result = VM::current()->scheduler()->send_message_from(process, process_id, message);
  if (result == MESSAGE_PERMISSION_DENIED) FAIL(PERMISSION_DENIED);
  // Sandboxed senders learn that they are flooding a mailbox. For other
  // senders the message is dropped, as for a missing receiver, so a full
  // sandboxed mailbox can't make the system process throw.
  if (result == MESSAGE_QUOTA_EXCEEDED && policy->restricts_messaging()) FAIL(QUOTA_EXCEEDED);
  return BOOL(result == MESSAGE_OK);
}

PRIMITIVE(process_grant_send) {
  PRIVILEGED;
  ARGS(int, pid, int, target);
  Scheduler::GrantResult result = VM::current()->scheduler()->grant_send(pid, target);
  if (result == Scheduler::GRANT_QUOTA_EXCEEDED) FAIL(QUOTA_EXCEEDED);
  return BOOL(result == Scheduler::GRANT_OK);
}

PRIMITIVE(process_policy) {
  ARGS(int, pid);
  return Smi::from(VM::current()->scheduler()->policy_kind(pid));
}

PRIMITIVE(pid_for_external_id) {
  ARGS(String, id)
  return Smi::from(pid_for_external_id(id));
}

Object* MessageEncoder::create_error_object(Process* process) {
  Object* result = null;
  if (malloc_failed_) {
    FAIL(MALLOC_FAILED);
  } else if (too_large_) {
    FAIL(OUT_OF_RANGE);
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
  // The library only calls this when task_has_messages is true, but a
  // program can call it at any time (found by verified/core/fuzz).
  if (message == null) return process->null_object();
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
    if (decoder.malformed_input()) {
      // Not produced by the encoder (it refuses what the decoder rejects).
      // Drop the message like a canceled one: the objects decoded so far
      // give their out-of-line data back to the message, and deleting it
      // frees all of it (keeping only the decoded part would leak the
      // out-of-line data after the error).
      decoder.remove_disposing_finalizers();
      process->remove_first_message();
      return process->null_object();
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
    bool already_active = object->has_active_finalizer();
    if (already_active) FAIL(ALREADY_EXISTS);
    if (!process->object_heap()->add_callable_finalizer(Instance::cast(object), finalizer, make_weak)) FAIL(MALLOC_FAILED);
  }
  return process->null_object();
}

PRIMITIVE(remove_finalizer) {
  ARGS(HeapObject, object)
  // Objects on the program heap never get a finalizer (see add_finalizer),
  // and they must not be modified.
  if (object->on_program_heap(process)) return BOOL(false);
  // Only instances get Toit finalizers (see add_finalizer). The same header
  // bit marks the VM finalizer of an external byte array or string, which
  // frees its memory: clearing it would leak the memory.
  if (!is_instance(object)) return BOOL(false);
  bool result = object->has_active_finalizer();
  if (result) process->object_heap()->remove_callable_finalizer(Instance::cast(object));
  return BOOL(result);
}

PRIMITIVE(gc_count) {
  return Smi::from(process->gc_count(NEW_SPACE_GC));
}

PRIMITIVE(create_off_heap_byte_array) {
  ARGS(int, length);
  if (length < 0) FAIL(NEGATIVE_ARGUMENT);

  AllocationManager allocation(process);
  uint8* buffer = allocation.alloc(length);
  if (buffer == null) FAIL(ALLOCATION_FAILED);

  // The memory comes from malloc. Clear it, so the program doesn't see what
  // the VM or other processes freed.
  ByteArray* result = process->object_heap()->allocate_external_byte_array(length, buffer, true, true);
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
  word new_length = new_array->length();
  // The probing below only stays in bounds and terminates for a non-empty
  // power-of-two index array.
  if (new_length == 0 || !Utils::is_power_of_two(new_length)) FAIL(INVALID_ARGUMENT);
  // Arrays on the program heap are shared and read-only.
  if (new_array->on_program_heap(process)) FAIL(PERMISSION_DENIED);
  word index_mask = new_length - 1;
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
    // Triangular probing visits every slot of a power-of-two array within
    // new_length steps. If there is no free slot, fail instead of looping
    // forever.
    while (new_array->at(slot) != 0) {
      if (step > new_length) FAIL(INVALID_ARGUMENT);
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
#ifdef TOIT_HW_PERF
  // Without a profiler: reset the hardware counters (hw_perf.h).
  if (profiler == null) {
    hw_perf_reset();
    return process->true_object();
  }
#endif
  if (profiler == null) FAIL(ALREADY_CLOSED);
  if (profiler->is_active()) return process->false_object();
  profiler->start();
  // Tell the scheduler that a new process has an active profiler.
  VM::current()->scheduler()->activate_profiler(process);
  return process->true_object();
}

PRIMITIVE(profiler_stop) {
  Profiler* profiler = process->profiler();
#ifdef TOIT_HW_PERF
  // Without a profiler: print the hardware counters (hw_perf.h).
  if (profiler == null) {
    hw_perf_dump();
    return process->true_object();
  }
#endif
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
  // The heap cap of the policy can not be raised by the program.
  word cap = process->policy()->quotas().max_heap_bytes;
  if (cap > 0 && (max_bytes <= 0 || max_bytes > cap)) max_bytes = cap;
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
  if (Primitive::is_error(tv_nsec)) return tv_nsec;
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
    .tv_sec = static_cast<time_t>(tv_sec),
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

#ifdef TOIT_EC618
// Canonical active-slot firmware view, implemented in primitive_ec618.cc. The
// dual-slot relocation is hidden here: firmware.map reads the running slot as
// its un-relocated, table-first canonical image so the SHA and delta-OTA are
// slot-independent.
uint32_t ec618_active_firmware_open(uint8** base_out);
uint8 ec618_active_firmware_at(uint32 index);
bool ec618_active_firmware_copy(uint32 from, uint32 to, uint8* dest);
#endif

PRIMITIVE(firmware_map) {
  ARGS(Object, bytes);
#if defined(TOIT_ESP32)
  if (bytes != process->null_object()) {
    return bytes;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (firmware_is_mapped) {
    spi_flash_munmap(firmware_mmap_handle);
    firmware_is_mapped = false;
    FAIL(QUOTA_EXCEEDED);
  }

  const esp_partition_t* current_partition = esp_ota_get_running_partition();
  if (current_partition == null) FAIL(ERROR);

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
#elif defined(TOIT_EC618)
  if (bytes != process->null_object()) {
    return bytes;
  }

  // On EC618 the firmware is the active VM slot. firmware.map presents it as its
  // canonical image — table-first and un-relocated — so the SHA and delta-OTA
  // are the same regardless of which slot is live; the dual-slot relocation is
  // hidden in SlotFirmware (primitive_ec618.cc / slot_reloc_ec618.*). The proxy
  // carries the slot's XIP base as a valid-but-unread external address; the
  // firmware_mapping_at/copy primitives read canonical bytes through the view.
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  uint8* base = null;
  uint32 canonical_size = ec618_active_firmware_open(&base);
  if (canonical_size == 0) FAIL(ERROR);
  proxy->set_external_address(canonical_size, base);
  return proxy;
#else
  return bytes;
#endif
}

PRIMITIVE(firmware_unmap) {
#ifdef TOIT_ESP32
  ARGS(ByteArray, proxy);
  if (!firmware_is_mapped) process->null_object();
  spi_flash_munmap(firmware_mmap_handle);
  firmware_is_mapped = false;
  proxy->clear_external_address();
#elif defined(TOIT_EC618)
  ARGS(ByteArray, proxy);
  proxy->clear_external_address();
#endif
  return process->null_object();
}

// Extracts the backing bytes, the offset, and the size of a firmware
// mapping, and checks that the mapping lies within the backing bytes.
// Returns null on success, and an error otherwise.
static Object* firmware_mapping_fields(Process* process, Instance* receiver, Blob* input, word* offset, word* size) {
  Object* offset_object = receiver->at(1);
  Object* size_object = receiver->at(2);
  if (!is_smi(offset_object) || !is_smi(size_object)) FAIL(WRONG_OBJECT_TYPE);
  if (!receiver->at(0)->byte_content(process->program(), input, STRINGS_OR_BYTE_ARRAYS)) {
    FAIL(WRONG_OBJECT_TYPE);
  }
  *offset = Smi::value(offset_object);
  *size = Smi::value(size_object);
  if (*offset < 0 || *size < 0 || *size > input->length() - *offset) FAIL(OUT_OF_BOUNDS);
  return null;
}

PRIMITIVE(firmware_mapping_at) {
  ARGS(Instance, receiver, int, index);
  Blob input;
  word offset;
  word size;
  Object* error = firmware_mapping_fields(process, receiver, &input, &offset, &size);
  if (error != null) return error;
  if (index < 0 || index >= size) FAIL(OUT_OF_BOUNDS);

#ifdef TOIT_EC618
  // The canonical byte is computed by the active-slot view (un-relocated),
  // not read from the proxy's external address.
  return Smi::from(ec618_active_firmware_at(static_cast<uint32>(offset + index)));
#else
  // Firmware is potentially mapped into memory that only allow word
  // access. We read the full word before masking and shifting. This
  // asssumes that we're running on a little endian platform.
  index += offset;
  const uint32* words = reinterpret_cast<const uint32*>(input.address());
  uint32 shifted = words[index >> 2] >> ((index & 3) << 3);
  return Smi::from(shifted & 0xff);
#endif
}

PRIMITIVE(firmware_mapping_copy) {
  ARGS(Instance, receiver, word, from, word, to, MutableBlob, output, word, index);
  if (index < 0) FAIL(OUT_OF_BOUNDS);
  Blob input;
  word offset;
  word size;
  Object* error = firmware_mapping_fields(process, receiver, &input, &offset, &size);
  if (error != null) return error;
  if (!Utils::is_aligned(from + offset, sizeof(uint32)) ||
      !Utils::is_aligned(to + offset, sizeof(uint32))) FAIL(INVALID_ARGUMENT);
  if (from > to || from < 0 || to > size) FAIL(OUT_OF_BOUNDS);

  word bytes = to - from;
  if (index + bytes > output.length()) FAIL(OUT_OF_BOUNDS);

#ifdef TOIT_EC618
  // Copy canonical (un-relocated) bytes through the active-slot view. The
  // window is word-aligned (checked above), so the body sub-window is too.
  if (!ec618_active_firmware_copy(static_cast<uint32>(from + offset),
                                  static_cast<uint32>(to + offset),
                                  output.address() + index)) {
    FAIL(INVALID_ARGUMENT);
  }
#else
  // Firmware is potentially mapped into memory that only allow word
  // access. We use an IRAM safe memcpy alternative that guarantees
  // always reading whole words to avoid issues with this.
  iram_safe_memcpy(output.address() + index, input.address() + from + offset, bytes);
#endif
  return Smi::from(index + bytes);
}

#if defined(TOIT_ESP32) || defined(TOIT_EC618)
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

PRIMITIVE(hostname) {
#if defined(TOIT_ESP32)
  return process->allocate_string_or_error(CONFIG_LWIP_LOCAL_HOSTNAME);
#elif defined(TOIT_WINDOWS)
  DWORD size = 0;
  GetComputerNameExW(ComputerNameDnsHostname, null, &size);
  wchar_t buffer[size];
  if (!GetComputerNameExW(ComputerNameDnsHostname, buffer, &size)) {
    return windows_error(process, GetLastError());
  }
  return process->allocate_string(buffer);
#elif defined(TOIT_POSIX)
  // The HOST_NAME_MAX variable isn't defined on all platforms, so we
  // just hardcode a good default. On my machine HOST_NAME_MAX is set to 64.
  // So 256 should be enough.
  char buffer[256];
  int result = gethostname(buffer, sizeof(buffer));
  if (result != 0) {
    return Primitive::os_error(errno, process);
  }
  buffer[sizeof(buffer) - 1] = '\0';
  // On macOS, the hostname might include the .local suffix, which we don't want.
  // Simply truncate at the first dot.
  char* dot = strchr(buffer, '.');
  if (dot != null) *dot = '\0';
  return process->allocate_string_or_error(buffer);
#elif defined(TOIT_EC618)
  return process->allocate_string_or_error("ec618");
#else
#error "Unsupported platform"
#endif

}

} // namespace toit

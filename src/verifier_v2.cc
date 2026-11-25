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

#include "verifier_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "interpreter_v2.h"
#include "primitive.h"
#include "program.h"
#include "flash_allocation.h"
#include "flash_registry.h"
#include "flags.h"
#include "os.h"
#include "process.h"

#ifdef TOIT_ESP32
#include <sdkconfig.h>
#endif
#ifdef CONFIG_TOIT_TRACE_INSTALL
#include <esp_heap_caps.h>
#include <esp_timer.h>

// The lowest free heap seen by an allocation while an install-time
// verification runs (Kconfig TOIT_TRACE_INSTALL selects HEAP_USE_HOOKS; the
// heap of the Toit IDF fork keeps no minimum of its own). Every allocation
// of the system counts, not only the verifier's.
static volatile bool trace_install_active = false;
static volatile size_t trace_install_min_free = 0;
// The times of the first and the last progress callback (before the first
// and the last method check): the conversion of the image and the decoding
// of the certificate come before the first.
static int64_t trace_install_first_progress = 0;
static int64_t trace_install_last_progress = 0;

// Without TOIT_TRACE_INSTALL_HEAP (times only) there are no heap hooks: the
// hook costs a free-size query per allocation, which inflates the time of
// an allocation-heavy verification; the peak use is then not measured.
#ifdef CONFIG_TOIT_TRACE_INSTALL_HEAP
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// The allocations of the installing task during a traced verification (other
// tasks, e.g. WiFi on the other core, are not counted): the number of
// requests, how many were 1 KB or more, the largest one, the peak of the
// task's live bytes, and the failed requests (the largest one and the
// largest free block when it failed).
static void* volatile trace_install_task = null;
static const int TRACE_INSTALL_SLOTS = 512;
static void* trace_install_ptr[TRACE_INSTALL_SLOTS];
static uint32_t trace_install_size[TRACE_INSTALL_SLOTS];
static int trace_install_used = 0;
static uint32_t trace_install_allocs, trace_install_1k, trace_install_2k, trace_install_4k;
static uint32_t trace_install_largest, trace_install_live, trace_install_live_peak, trace_install_untracked;
static uint32_t trace_install_failed, trace_install_failed_largest, trace_install_failed_block;

static bool trace_install_mine() {
  return trace_install_active && xTaskGetCurrentTaskHandle() == trace_install_task;
}

static int trace_install_find(void* ptr) {
  for (int i = 0; i < trace_install_used; i++) {
    if (trace_install_ptr[i] == ptr) return i;
  }
  return -1;
}

extern "C" void esp_heap_trace_alloc_hook(void* ptr, size_t size, uint32_t caps) {
  if (!trace_install_active) return;
  size_t now = heap_caps_get_free_size(MALLOC_CAP_8BIT);
  if (now < trace_install_min_free) trace_install_min_free = now;
  if (!trace_install_mine()) return;
  trace_install_allocs++;
  if (size >= 1024) trace_install_1k++;
  if (size >= 2048) trace_install_2k++;
  if (size >= 4096) trace_install_4k++;
  if (size > trace_install_largest) trace_install_largest = size;
  int i = trace_install_find(ptr);  // A reallocation in place.
  if (i >= 0) {
    trace_install_live += size - trace_install_size[i];
    trace_install_size[i] = size;
  } else if (trace_install_used < TRACE_INSTALL_SLOTS) {
    trace_install_ptr[trace_install_used] = ptr;
    trace_install_size[trace_install_used] = size;
    trace_install_used++;
    trace_install_live += size;
  } else {
    trace_install_untracked++;
  }
  if (trace_install_live > trace_install_live_peak) trace_install_live_peak = trace_install_live;
}

extern "C" void esp_heap_trace_free_hook(void* ptr) {
  if (!trace_install_mine()) return;
  int i = trace_install_find(ptr);
  if (i < 0) return;  // Allocated before the verification.
  trace_install_live -= trace_install_size[i];
  trace_install_used--;
  trace_install_ptr[i] = trace_install_ptr[trace_install_used];
  trace_install_size[i] = trace_install_size[trace_install_used];
}

static void trace_install_failed_alloc(size_t size, uint32_t caps, const char* function_name) {
  if (!trace_install_mine()) return;
  trace_install_failed++;
  if (size > trace_install_failed_largest) {
    trace_install_failed_largest = size;
    trace_install_failed_block = heap_caps_get_largest_free_block(caps);
  }
}

static void trace_install_heap_start() {
  heap_caps_register_failed_alloc_callback(&trace_install_failed_alloc);
  trace_install_task = xTaskGetCurrentTaskHandle();
  trace_install_used = 0;
  trace_install_allocs = trace_install_1k = trace_install_2k = trace_install_4k = 0;
  trace_install_largest = trace_install_live = trace_install_live_peak = trace_install_untracked = 0;
  trace_install_failed = trace_install_failed_largest = trace_install_failed_block = 0;
}

static void trace_install_heap_print() {
  printf("[install-trace] heap: %u requests (%u >= 1 KB, %u >= 2 KB, %u >= 4 KB), largest %u B,"
         " live peak %u B, still live %u B (%d blocks), untracked %u; %u failed (largest %u B, largest free block then %u B)\n",
         static_cast<unsigned>(trace_install_allocs), static_cast<unsigned>(trace_install_1k),
         static_cast<unsigned>(trace_install_2k), static_cast<unsigned>(trace_install_4k),
         static_cast<unsigned>(trace_install_largest), static_cast<unsigned>(trace_install_live_peak),
         static_cast<unsigned>(trace_install_live), trace_install_used,
         static_cast<unsigned>(trace_install_untracked), static_cast<unsigned>(trace_install_failed),
         static_cast<unsigned>(trace_install_failed_largest), static_cast<unsigned>(trace_install_failed_block));
}
#endif
#endif

namespace toit {

const char* const V2Verifier::OUT_OF_MEMORY = "OUT_OF_MEMORY";

// The VM's primitive table, from the same declarations the primitives are
// compiled from (primitive.h): the verifier checks every PRIMITIVE
// instruction against these arities.
#define V2_ARITY_ONE(name, arity) arity,
#define V2_MODULE_ARITIES(name, entries) entries(V2_ARITY_ONE)
#define V2_MODULE_COUNT(name, entries) 0 entries(MODULE_PRIMITIVE_COUNT_ONE),
static const uint8 v2_prim_arities[] = { MODULES(V2_MODULE_ARITIES) };
static const uint32 v2_prim_counts[] = { MODULES(V2_MODULE_COUNT) };
#undef V2_ARITY_ONE
#undef V2_MODULE_ARITIES
#undef V2_MODULE_COUNT

// Whether `length` elements of `element_size` bytes at `data` lie inside
// [begin, end) and `data` has the alignment the readers need.
static bool v2_inside(uword begin, uword end, const void* data, word length, word element_size,
                      uword alignment) {
  if (length < 0) return false;
  if (length == 0) return true;  // Never read.
  uword a = reinterpret_cast<uword>(data);
  if ((a & (alignment - 1)) != 0 || a < begin || a >= end) return false;
  return static_cast<uword>(length) <= (end - a) / static_cast<uword>(element_size);
}

// The tables of a program image lie inside the image, before anything
// reads them (verified/cxx/annotated/README.md, "Findings", wave 11). A
// program image is a Program followed by its heap and its off-heap
// tables; the image's words are installed as they come, so every pointer
// of the Program (the List and Table fields) is a word the image chose:
// with the relocation bit, an offset into the image; without it, any
// address. Everything after this reads them: is_format2 the bytecodes,
// V2MethodTable::compute the last literal and the method table literal it
// holds, v2_program_tables and the verifier's conversion every table
// (verified/vmverify/src/from_vm.rs borrows them in place: "Every pointer
// of `p` must be valid for its length"), the processes the globals.
// Memory outside the image is neither checked by the verifier nor
// immutable after it (a table at an absolute address in RAM could change
// after the verdict). The snapshot reader allocates all of them inside the
// image, so a program read from a snapshot passes. Returns null or the
// reason.
const char* V2Verifier::image_layout_error(const Program* program, word program_size) {
  uword begin = reinterpret_cast<uword>(program);
  if (program_size < static_cast<word>(sizeof(Program)) ||
      static_cast<uword>(program_size) > ~static_cast<uword>(0) - begin) {
    return "program size";
  }
  uword end = begin + program_size;
  if (!v2_inside(begin, end, program->global_variables.array(), program->global_variables.length(),
                 sizeof(Object*), WORD_SIZE)) {
    return "global variables outside the image";
  }
  if (!v2_inside(begin, end, program->literals.array(), program->literals.length(), sizeof(Object*), WORD_SIZE)) {
    return "literals outside the image";
  }
  if (!v2_inside(begin, end, program->dispatch_table.data(), program->dispatch_table.length(), sizeof(int32), 4)) {
    return "dispatch table outside the image";
  }
  if (!v2_inside(begin, end, program->class_check_ids.data(), program->class_check_ids.length(), sizeof(uint16), 2)) {
    return "class check ids outside the image";
  }
  if (!v2_inside(begin, end, program->interface_check_offsets.data(), program->interface_check_offsets.length(),
                 sizeof(uint16), 2)) {
    return "interface check offsets outside the image";
  }
  if (!v2_inside(begin, end, program->class_bits.data(), program->class_bits.length(), sizeof(uint16), 2)) {
    return "class bits outside the image";
  }
  if (!v2_inside(begin, end, program->bytecodes.data(), program->bytecodes.length(), 1, 1)) {
    return "bytecodes outside the image";
  }
  // The last literal: V2MethodTable::compute reads its header and, for a
  // byte array, its content (the method table, format note 21).
  int count = program->literals.length();
  if (count > 0) {
    Object* last = program->literals.array()[count - 1];
    if (is_heap_object(last)) {
      // The header and the length word.
      void* object = reinterpret_cast<void*>(reinterpret_cast<uword>(last) - Object::HEAP_TAG);
      if (!v2_inside(begin, end, object, 2, WORD_SIZE, WORD_SIZE)) return "last literal outside the image";
      if (is_byte_array(last)) {
        const ByteArray* array = ByteArray::cast(last);
        if (array->has_external_address()) {
          if (!v2_inside(begin, end, object, ByteArray::external_allocation_size() / WORD_SIZE, WORD_SIZE, WORD_SIZE)) {
            return "last literal outside the image";
          }
          if (array->external_tag() != RawByteTag) return "method table literal is not raw bytes";
        }
        ByteArray::ConstBytes bytes(array);
        if (bytes.address() == null || !v2_inside(begin, end, bytes.address(), bytes.length(), 1, 1)) {
          return "method table literal outside the image";
        }
      }
    }
  }
  return null;
}

// The builtin classes and roots the C++ VM uses without checks
// (verified/cxx/annotated/README.md, "Findings", wave 11): every builtin
// class id is a class with the tag the VM assumes for it, and the builtin
// classes whose fields the C++ reads or writes by index (the primitives'
// argument decoders, list_add, the message encoder, the interpreter's
// fast paths) have at least those fields. A program brings its own core
// library, so these are its classes; the format-2 verifier itself checks
// only the classes the verified core allocates or dispatches on (`tables_ok`
// in verified/spec/src/v2/verifier.rs). The same checks as the format-1
// verifier's (src/verifier.cc check_builtin_classes). The roots are read
// only after the verifier's conversion accepted them as objects of the
// image (verified/vmverify/src/from_vm.rs). Returns null or the reason.
const char* V2Verifier::builtin_classes_error(Program* program) {
  int class_count = program->class_bits.length();
  struct { Smi* id; int tag; int fields; const char* name; } builtins[] = {
    { program->string_class_id(), STRING_TAG, 0, "string" },
    { program->array_class_id(), ARRAY_TAG, 0, "array" },
    { program->byte_array_class_id(), BYTE_ARRAY_TAG, 0, "byte array" },
    { program->byte_array_cow_class_id(), INSTANCE_TAG, Instance::BYTE_ARRAY_COW_IS_MUTABLE_INDEX + 1, "byte array cow" },
    { program->byte_array_slice_class_id(), INSTANCE_TAG, Instance::BYTE_ARRAY_SLICE_TO_INDEX + 1, "byte array slice" },
    { program->string_slice_class_id(), INSTANCE_TAG, Instance::STRING_SLICE_TO_INDEX + 1, "string slice" },
    { program->string_byte_slice_class_id(), INSTANCE_TAG, Instance::STRING_BYTE_SLICE_TO_INDEX + 1, "string byte slice" },
    { program->list_class_id(), INSTANCE_TAG, Instance::LIST_SIZE_INDEX + 1, "list" },
    { program->list_slice_class_id(), INSTANCE_TAG, Instance::LIST_SLICE_TO_INDEX + 1, "list slice" },
    { program->map_class_id(), INSTANCE_TAG, Instance::MAP_BACKING_INDEX + 1, "map" },
    { program->tombstone_class_id(), INSTANCE_TAG, Instance::TOMBSTONE_DISTANCE_INDEX + 1, "tombstone" },
    { program->stack_class_id(), STACK_TAG, 0, "stack" },
    { program->null_class_id(), ODDBALL_TAG, 0, "null" },
    { program->true_class_id(), ODDBALL_TAG, 0, "true" },
    { program->false_class_id(), ODDBALL_TAG, 0, "false" },
    { program->object_class_id(), INSTANCE_TAG, 0, "object" },
    { program->double_class_id(), DOUBLE_TAG, 0, "double" },
    { program->large_integer_class_id(), LARGE_INTEGER_TAG, 0, "large integer" },
    { program->smi_class_id(), INSTANCE_TAG, 0, "smi" },
    { program->task_class_id(), TASK_TAG, 2, "task" },
    { program->large_array_class_id(), INSTANCE_TAG, Instance::LARGE_ARRAY_VECTOR_INDEX + 1, "large array" },
    { program->lazy_initializer_class_id(), INSTANCE_TAG, 1, "lazy initializer" },
    { program->exception_class_id(), INSTANCE_TAG, 2, "exception" },
  };
  for (auto& b : builtins) {
    if (!is_smi(b.id)) return "builtin class: an id is not a smi";
    word id = Smi::value(b.id);
    if (id < 0 || id >= class_count) return "builtin class: an id out of range";
    int bits = program->class_bits[id];
    if (Program::class_tag_from_class_bits(bits) != b.tag) return "builtin class: a class without the tag the VM assumes";
    if (b.fields > 0 &&
        Instance::fields_from_size(Program::instance_size_from_class_bits(bits)) < b.fields) {
      return "builtin class: a class with fewer fields than the VM reads";
    }
  }
  auto is_oddball_of = [&](Object* object, Smi* class_id) {
    return is_heap_object(object) && HeapObject::cast(object)->class_id() == class_id &&
        HeapObject::cast(object)->class_tag() == ODDBALL_TAG;
  };
  if (!is_oddball_of(program->null_object(), program->null_class_id()) ||
      !is_oddball_of(program->true_object(), program->true_class_id()) ||
      !is_oddball_of(program->false_object(), program->false_class_id())) {
    return "builtin root: null, true or false is not the oddball of its class";
  }
  if (!is_array(program->empty_array()) || Array::cast(program->empty_array())->length() != 0) {
    return "builtin root: empty_array is not an empty array";
  }
  if (!is_instance(program->out_of_memory_error()) ||
      Instance::cast(program->out_of_memory_error())->class_id() != program->exception_class_id()) {
    return "builtin root: out_of_memory_error is not an exception";
  }
  for (int i = Program::app_sdk_version_INDEX; i < Program::ROOT_COUNT; i++) {
    if (!is_string(program->root(i))) return "builtin root: a string root is not a string";
  }
  return null;
}

const char* V2Verifier::install_verdict(const void* memory, word program_size, uint8* metadata,
                                        const uint8* certificate, word certificate_length,
                                        Process* process) {
  metadata[0] &= ~FlashAllocation::Header::FLAGS_PROGRAM_VERIFIED_MASK;
  if ((metadata[0] & FlashAllocation::Header::FLAGS_PROGRAM_UNTRUSTED_MASK) == 0) return null;
  FlashRegistry::flush();
  Program* program = reinterpret_cast<Program*>(const_cast<void*>(memory));
  bool no_verdict = false;
  const char* error = verify_installed(program, program_size, &no_verdict, certificate, certificate_length,
                                       process);
  if (error != null) return error;
  if (!no_verdict) metadata[0] |= FlashAllocation::Header::FLAGS_PROGRAM_VERIFIED_MASK;
  return null;
}

bool V2Verifier::infers() {
#ifdef TOIT_VERIFIED_CORE_INFER
  if (Flags::require_certificate) return false;
  const char* env = getenv("TOIT_REQUIRE_CERTIFICATE");
  return env == null || strcmp(env, "1") != 0;
#else
  return false;
#endif
}

#ifdef TOIT_VERIFIED_CORE

static void v2_input(Program* program, const V2MethodTable* table, bool trusted,
                     toit_v2_program* tables, toit_vmverify_input* input, word program_size = -1,
                     const uint8* certificate = null, word certificate_length = 0) {
  // The program's initial global values: the process' globals start as a
  // copy of them.
  v2_program_tables(program, table, program->global_variables.array(), tables);
  // At install time the allocation header (which holds the size) is not
  // written yet.
  if (program_size >= 0) tables->program_heap_size = program_size;
  input->program = tables;
  input->prim_counts = v2_prim_counts;
  input->prim_module_count = ARRAY_SIZE(v2_prim_counts);
  input->prim_arities = v2_prim_arities;
  input->prim_arities_length = ARRAY_SIZE(v2_prim_arities);
  input->trusted = trusted ? 1 : 0;
  input->certificate = certificate;
  input->certificate_length = certificate == null ? 0 : certificate_length;
  input->progress = null;
  input->progress_context = null;
}

// The context of the verifier's progress callback.
struct V2Progress {
  Process* process;  // Or null.
  uword calls;
};

// The verifier's progress callback (toit_vmverify_input::progress), called
// before each method: the verification runs inside one primitive of the
// process, which the scheduler's dead-lock check would otherwise kill
// after PROCESS_MAX_RUN_TIME_US (scheduler.cc). Touches nothing the
// verifier reads.
static void v2_progress(void* context, uword method) {
  V2Progress* progress = reinterpret_cast<V2Progress*>(context);
  progress->calls++;
#ifdef CONFIG_TOIT_TRACE_INSTALL
  if (trace_install_active) {
    int64 now = esp_timer_get_time();
    if (trace_install_first_progress == 0) trace_install_first_progress = now;
    trace_install_last_progress = now;
  }
#endif
  if (progress->process != null) progress->process->note_progress(OS::get_monotonic_time());
}

static const char* v2_code_name(uword code) {
  switch (code) {
    case TOIT_VMVERIFY_MALFORMED: return "malformed program memory";
    case TOIT_VMVERIFY_HEAP: return "program heap";
    case TOIT_VMVERIFY_TABLES: return "program tables";
    case TOIT_VMVERIFY_METHOD: return "method";
    case TOIT_VMVERIFY_INTERNAL: return "verifier failure";
    case TOIT_VMVERIFY_CERTIFICATE: return "shipped certificate";
    case TOIT_VMVERIFY_NO_CERTIFICATE: return "no certificate";
    case TOIT_VMVERIFY_OUT_OF_MEMORY: return "out of memory";
    default: return "unknown";
  }
}

bool V2Verifier::is_available() { return true; }

// The panic handler of the Rust library on devices (no_std, panic = abort:
// verified/vmverify/src/device.rs). Hosts catch the verifier's panics in
// Rust instead and never call this.
extern "C" void toit_vmverify_panic(const uint8* file, uword length) {
  FATAL("Rust panic in %.*s", static_cast<int>(length), reinterpret_cast<const char*>(file));
}

static bool v2_verify(Program* program, const V2MethodTable* table, bool trusted, word program_size,
                      const uint8* certificate, word certificate_length, Process* process,
                      bool* out_of_memory = null);

bool V2Verifier::verify(Program* program, const V2MethodTable* table, bool trusted,
                        const uint8* certificate, word certificate_length) {
  return v2_verify(program, table, trusted, -1, certificate, certificate_length, null);
}

static bool v2_verify(Program* program, const V2MethodTable* table, bool trusted, word program_size,
                      const uint8* certificate, word certificate_length, Process* process,
                      bool* out_of_memory) {
#ifdef TOIT_NO_V2_VERIFIER
  // Firmware that never installs untrusted containers (Kconfig
  // TOIT_VERIFIED_CORE_VERIFIER): the verifier is not linked, so every
  // untrusted program is rejected.
  USE(v2_progress);
  USE(v2_code_name);
  fprintf(stderr, "verifier: %sprogram rejected: the firmware has no verifier\n", trusted ? "" : "untrusted ");
  return false;
#else
  // The tables the conversion borrows lie inside the image (checked before
  // the method table was decoded on the install path; a program read from
  // a snapshot has them there by construction).
  const char* layout = V2Verifier::image_layout_error(program,
      program_size >= 0 ? program_size : program->size_no_assets());
  if (layout != null) {
    fprintf(stderr, "verifier: %sprogram rejected: malformed program memory: %s\n",
            trusted ? "" : "untrusted ", layout);
    return false;
  }
  if (certificate == null && !V2Verifier::infers()) {
    // Devices (and hosts with -Xrequire_certificate): no inference, so no
    // verdict without a shipped certificate. Rejected before the program is
    // converted.
    fprintf(stderr, "verifier: %sprogram rejected: %s\n", trusted ? "" : "untrusted ",
            v2_code_name(TOIT_VMVERIFY_NO_CERTIFICATE));
    return false;
  }
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, trusted, &tables, &input, program_size, certificate, certificate_length);
  V2Progress progress = { process, 0 };
  input.progress = &v2_progress;
  input.progress_context = &progress;
  toit_vmverify_result result;
  toit_vmverify_verify(&input, &result);
  result.message[TOIT_VMVERIFY_MESSAGE_SIZE - 1] = '\0';
#ifndef TOIT_FREERTOS
  // Hosts only (devices have no environment; Kconfig TOIT_TRACE_INSTALL
  // traces their installs).
  const char* timing = getenv("TOIT_VERIFY_TIME");
  if (timing != null && strcmp(timing, "1") == 0) {
    fprintf(stderr,
            "verifier: %s%s, %" PRIdPTR " methods, %" PRIuPTR " bytecodes, %" PRIuPTR " objects;"
            " convert %.2f ms, heap %.2f ms, infer %.2f ms, check %.2f ms; peak %" PRIuPTR " KB;"
            " progress %" PRIuPTR "%s\n",
            result.code == TOIT_VMVERIFY_ACCEPTED ? "accepted" : "rejected",
            certificate != null ? " (shipped certificate)" : "",
            table->length(), static_cast<uword>(program->bytecodes.length()), result.objects,
            result.convert_ns / 1e6, result.heap_ns / 1e6, result.infer_ns / 1e6,
            result.check_ns / 1e6, result.peak_bytes >> 10,
            progress.calls, process != null ? " (to the scheduler)" : "");
  }
#endif
  if (result.code == TOIT_VMVERIFY_ACCEPTED) {
    // The builtin classes and roots the C++ relies on (after the
    // conversion accepted the roots as objects of the image).
    const char* builtin = V2Verifier::builtin_classes_error(program);
    if (builtin != null) {
      fprintf(stderr, "verifier: %sprogram rejected: %s\n", trusted ? "" : "untrusted ", builtin);
      return false;
    }
    // The only place that marks a table verified (the core's verified run
    // loop relies on it: Interpreter::run_v2).
    const_cast<V2MethodTable*>(table)->mark_verified(trusted);
    return true;
  }
  if (out_of_memory != null) *out_of_memory = result.code == TOIT_VMVERIFY_OUT_OF_MEMORY;
  const char* kind = trusted ? "" : "untrusted ";
  if (result.method >= 0 && table->is_valid(result.method)) {
    word bci = table->at(result.method).entry + (result.offset >= 0 ? result.offset : 0);
    fprintf(stderr, "verifier: %sprogram rejected: method %" PRIdPTR " at bci %" PRIdPTR " (+%" PRIdPTR "): %s\n",
            kind, result.method, bci, result.offset, result.message);
  } else {
    fprintf(stderr, "verifier: %sprogram rejected: %s: %s\n",
            kind, v2_code_name(result.code), result.message);
  }
  // (`message` is an array: devices build with -Werror=address.)
  if (!trusted && strstr(result.message, "not in the unchecked mode") != null) {
    // The compiler's default is first-party code with the trusted-only
    // twins (docs/format2-migration.md).
    fprintf(stderr, "verifier: the program was compiled for trusted use; compile it with --untrusted\n");
  }
  return false;
#endif  // TOIT_NO_V2_VERIFIER
}

const char* V2Verifier::verify_installed(Program* program, word program_size, bool* no_verdict,
                                         const uint8* certificate, word certificate_length,
                                         Process* process) {
  *no_verdict = false;
  const char* layout = image_layout_error(program, program_size);
  if (layout != null) {
    fprintf(stderr, "verifier: untrusted program rejected: malformed program memory: %s\n", layout);
    return "INVALID_SNAPSHOT";
  }
  if (!program->is_format2()) {
    if (V2MethodTable::untrusted_format1_allowed()) {
      *no_verdict = true;
      return null;
    }
    fprintf(stderr, "untrusted images must be in bytecode format 2 (use -Xuntrusted_format1 to allow format 1)\n");
    return "FORMAT_2_REQUIRED";
  }
  bool out_of_memory = false;
#ifdef CONFIG_TOIT_TRACE_INSTALL
  // Kconfig TOIT_TRACE_INSTALL: the time and the heap use of each
  // install-time verification (for measurements on a device or in QEMU).
  size_t trace_free = heap_caps_get_free_size(MALLOC_CAP_8BIT);
  size_t trace_largest = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
  trace_install_min_free = trace_free;
#ifdef CONFIG_TOIT_TRACE_INSTALL_HEAP
  trace_install_heap_start();
#endif
  trace_install_active = true;
  int64 trace_start = esp_timer_get_time();
  trace_install_first_progress = 0;
  trace_install_last_progress = 0;
#endif
  V2MethodTable* table = V2MethodTable::compute(program, &out_of_memory);
#ifdef CONFIG_TOIT_TRACE_INSTALL
  size_t trace_after_table = heap_caps_get_free_size(MALLOC_CAP_8BIT);
  int64 trace_table_end = esp_timer_get_time();
  if (table == null) trace_install_active = false;
#endif
  if (table == null) return out_of_memory ? OUT_OF_MEMORY : "INVALID_SNAPSHOT";
  bool accepted = v2_verify(program, table, false, program_size, certificate, certificate_length, process,
                            &out_of_memory);
#ifdef CONFIG_TOIT_TRACE_INSTALL
  int64 trace_end = esp_timer_get_time();
  trace_install_active = false;
  size_t trace_min = trace_install_min_free;
  // The table's size is the drop in free heap while it was computed; other
  // tasks (WiFi on the other core) can free memory meanwhile, so it is
  // signed.
  printf("[install-trace] %s: %d methods, %d bytecodes; free %u largest %u; table %d B (%s);"
         " peak use %u B (min free %u); %lld us\n",
         accepted ? "accepted" : "rejected", static_cast<int>(table->length()),
         static_cast<int>(program->bytecodes.length()),
         static_cast<unsigned>(trace_free), static_cast<unsigned>(trace_largest),
         static_cast<int>(static_cast<word>(trace_free) - static_cast<word>(trace_after_table)),
         table->in_literal() ? "literal" : "RAM",
         static_cast<unsigned>(trace_free - trace_min), static_cast<unsigned>(trace_min),
         static_cast<long long>(trace_end - trace_start));
  if (trace_install_first_progress != 0) {
    printf("[install-trace] table %lld us, convert and certificate %lld us, methods %lld us, after %lld us\n",
           static_cast<long long>(trace_table_end - trace_start),
           static_cast<long long>(trace_install_first_progress - trace_table_end),
           static_cast<long long>(trace_install_last_progress - trace_install_first_progress),
           static_cast<long long>(trace_end - trace_install_last_progress));
  }
#ifdef CONFIG_TOIT_TRACE_INSTALL_HEAP
  trace_install_heap_print();
#endif
#endif
  delete table;
  if (accepted) return null;
  return out_of_memory ? OUT_OF_MEMORY : "VERIFICATION_FAILED";
}

void V2Verifier::accept_recorded(const V2MethodTable* table) {
  const_cast<V2MethodTable*>(table)->mark_verified(false);
}

bool V2Verifier::write_canonical(Program* program, const V2MethodTable* table, const char* path) {
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, false, &tables, &input);
  return toit_vmverify_canonical(&input, path) == 0;
}

#ifdef TOIT_VERIFIED_CORE_INFER
// Builds with the inference only (hosts): devices link the verifier without
// it.
bool V2Verifier::certify(Program* program, const V2MethodTable* table, bool trusted,
                         uint8** bytes, word* length) {
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, trusted, &tables, &input);
  uint8* rust_bytes = null;
  uword rust_length = 0;
  uword code = toit_vmverify_certify(&input, &rust_bytes, &rust_length);
  if (code != 0) {
    fprintf(stderr, "certify: %s\n", code == 1
        ? "malformed program memory"
        : "no certificate the verifier accepts (run toit.run --verify for the reason)");
    return false;
  }
  *bytes = unvoid_cast<uint8*>(malloc(rust_length));
  if (*bytes == null) {
    toit_vmverify_free_certificate(rust_bytes, rust_length);
    return false;
  }
  memcpy(*bytes, rust_bytes, rust_length);
  *length = rust_length;
  toit_vmverify_free_certificate(rust_bytes, rust_length);
  return true;
}
#else
bool V2Verifier::certify(Program* program, const V2MethodTable* table, bool trusted,
                         uint8** bytes, word* length) {
  return false;
}
#endif

#else  // !TOIT_VERIFIED_CORE

bool V2Verifier::is_available() { return false; }

bool V2Verifier::verify(Program* program, const V2MethodTable* table, bool trusted,
                        const uint8* certificate, word certificate_length) {
  USE(v2_prim_arities);
  USE(v2_prim_counts);
  fprintf(stderr, "verifier: format-2 programs need the verified core (TOIT_VERIFIED_CORE)\n");
  return false;
}

bool V2Verifier::write_canonical(Program* program, const V2MethodTable* table, const char* path) {
  return false;
}

const char* V2Verifier::verify_installed(Program* program, word program_size, bool* no_verdict,
                                         const uint8* certificate, word certificate_length,
                                         Process* process) {
  if (image_layout_error(program, program_size) != null) {
    *no_verdict = false;
    return "INVALID_SNAPSHOT";
  }
  *no_verdict = !program->is_format2() && V2MethodTable::untrusted_format1_allowed();
  if (*no_verdict) return null;
  // Without the verifier no untrusted program can be admitted.
  return program->is_format2() ? "VERIFICATION_FAILED" : "FORMAT_2_REQUIRED";
}

void V2Verifier::accept_recorded(const V2MethodTable* table) {
  // Never reached: no allocation gets a verdict without the verifier.
}

bool V2Verifier::certify(Program* program, const V2MethodTable* table, bool trusted,
                         uint8** bytes, word* length) {
  return false;
}

#endif  // TOIT_VERIFIED_CORE

bool V2Verifier::verify(Program* program, bool trusted) {
  const char* layout = image_layout_error(program, program->size_no_assets());
  if (layout != null) {
    fprintf(stderr, "verifier: %sprogram rejected: malformed program memory: %s\n",
            trusted ? "" : "untrusted ", layout);
    return false;
  }
  V2MethodTable* table = V2MethodTable::compute(program);
  if (table == null) return false;
  bool result = verify(program, table, trusted);
  delete table;
  return result;
}

}  // namespace toit

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

#include "primitive_policy.h"

#include "messaging.h"
#include "objects_inline.h"
#include "process.h"

namespace toit {

namespace {

#define MODULE_ENUM(name, entries) MODULE_INDEX_##name,
enum {
  MODULES(MODULE_ENUM)
  MODULE_INDEX_COUNT
};
#undef MODULE_ENUM

#define PRIMITIVE_INDEX(name, arity) name,

struct CoreIndex {
  enum Enum {
    MODULE_CORE(PRIMITIVE_INDEX)
    count
  };
};

struct BitmapIndex {
  enum Enum {
    MODULE_BITMAP(PRIMITIVE_INDEX)
    count
  };
};

#undef PRIMITIVE_INDEX

#define PRIMITIVE_COUNT(name, arity) + 1
static const unsigned CORE_COUNT = 0 MODULE_CORE(PRIMITIVE_COUNT);
static const unsigned BITMAP_COUNT = 0 MODULE_BITMAP(PRIMITIVE_COUNT);
#undef PRIMITIVE_COUNT

// The core primitives an untrusted program may call. This is the set the
// core library needs (measured on the test suite) plus the remaining pure,
// process-local primitives and read-only clock access. Anything that reaches
// the host, flash, the environment, other processes (beyond process_send,
// which is gated separately), writes the clock, or changes VM-global
// settings is not in this list.
//
// Deliberately left out although process-local, because no ordinary program
// needs them: external and off-heap byte arrays (byte_array_new_external,
// create_off_heap_byte_array: `ByteArray n` still works for every n),
// get_generic_resource_group (only used by denied modules), encode_object,
// literal_index, bytes_allocated_delta, random_seed, and the SDK version
// queries (vm_sdk_version, vm_sdk_model, app_sdk_version, app_sdk_info).
static const uint16 UNTRUSTED_CORE[] = {
  // Measured set.
  CoreIndex::add_finalizer,
  CoreIndex::array_at,
  CoreIndex::array_at_put,
  CoreIndex::array_expand,
  CoreIndex::array_length,
  CoreIndex::array_new,
  CoreIndex::array_replace,
  CoreIndex::blob_equals,
  CoreIndex::blob_hash_code,
  CoreIndex::blob_index_of,
  CoreIndex::byte_array_at,
  CoreIndex::byte_array_at_put,
  CoreIndex::byte_array_convert_to_string,
  CoreIndex::byte_array_is_raw_bytes,
  CoreIndex::byte_array_length,
  CoreIndex::byte_array_new,
  CoreIndex::byte_array_replace,
  CoreIndex::compare_to,
  CoreIndex::concat_strings,
  CoreIndex::count_leading_zeros,
  CoreIndex::encode_error,
  CoreIndex::float_unary_minus,
  CoreIndex::float_add,
  CoreIndex::float_subtract,
  CoreIndex::float_multiply,
  CoreIndex::float_divide,
  CoreIndex::float_mod,
  CoreIndex::float_round,
  CoreIndex::float_parse,
  CoreIndex::float_sign,
  CoreIndex::float_is_nan,
  CoreIndex::float_is_finite,
  CoreIndex::float_less_than,
  CoreIndex::float_less_than_or_equal,
  CoreIndex::float_greater_than,
  CoreIndex::float_greater_than_or_equal,
  CoreIndex::float_equals,
  CoreIndex::float_to_string,
  CoreIndex::float_to_raw,
  CoreIndex::float_to_raw32,
  CoreIndex::float_sqrt,
  CoreIndex::float_ceil,
  CoreIndex::float_floor,
  CoreIndex::float_trunc,
  CoreIndex::int64_to_string,
  CoreIndex::large_integer_unary_minus,
  CoreIndex::large_integer_not,
  CoreIndex::large_integer_and,
  CoreIndex::large_integer_or,
  CoreIndex::large_integer_xor,
  CoreIndex::large_integer_shift_right,
  CoreIndex::large_integer_unsigned_shift_right,
  CoreIndex::large_integer_shift_left,
  CoreIndex::large_integer_add,
  CoreIndex::large_integer_subtract,
  CoreIndex::large_integer_multiply,
  CoreIndex::large_integer_divide,
  CoreIndex::large_integer_mod,
  CoreIndex::large_integer_equals,
  CoreIndex::large_integer_less_than,
  CoreIndex::large_integer_less_than_or_equal,
  CoreIndex::large_integer_greater_than,
  CoreIndex::large_integer_greater_than_or_equal,
  CoreIndex::list_add,
  CoreIndex::min_special_compare_to,
  CoreIndex::number_to_float,
  CoreIndex::number_to_integer,
  CoreIndex::object_class_id,
  CoreIndex::process_current_id,
  CoreIndex::process_send,
  CoreIndex::process_system_id,
  CoreIndex::random,
  CoreIndex::rebuild_hash_index,
  CoreIndex::remove_finalizer,
  CoreIndex::smi_unary_minus,
  CoreIndex::smi_not,
  CoreIndex::smi_and,
  CoreIndex::smi_or,
  CoreIndex::smi_xor,
  CoreIndex::smi_add,
  CoreIndex::smi_subtract,
  CoreIndex::smi_multiply,
  CoreIndex::smi_divide,
  CoreIndex::smi_mod,
  CoreIndex::smi_less_than,
  CoreIndex::smi_less_than_or_equal,
  CoreIndex::smi_greater_than,
  CoreIndex::smi_greater_than_or_equal,
  CoreIndex::smi_equals,
  CoreIndex::smi_shift_right,
  CoreIndex::smi_unsigned_shift_right,
  CoreIndex::smi_shift_left,
  CoreIndex::smi_to_string_base_10,
  CoreIndex::string_add,
  CoreIndex::string_at,
  CoreIndex::string_compare,
  CoreIndex::string_hash_code,
  CoreIndex::string_length,
  CoreIndex::string_raw_at,
  CoreIndex::string_slice,
  CoreIndex::string_write_to_byte_array,
  CoreIndex::string_rune_count,
  CoreIndex::task_has_messages,
  CoreIndex::task_new,
  CoreIndex::task_receive_message,
  CoreIndex::task_transfer,
  CoreIndex::time,
  CoreIndex::compare_simple_json_string,
  CoreIndex::hash_simple_json_string,
  CoreIndex::json_skip_whitespace,
  CoreIndex::size_of_json_number,
  CoreIndex::int_parse,
  CoreIndex::read_int_big_endian,
  CoreIndex::read_uint_big_endian,
  CoreIndex::read_int_little_endian,
  CoreIndex::read_uint_little_endian,
  CoreIndex::put_uint_big_endian,
  CoreIndex::put_uint_little_endian,
  CoreIndex::put_float_64_little_endian,
  CoreIndex::put_float_32_little_endian,

  // Read-only clock access (Time.now, Time.local). Setting the clock or the
  // time zone stays denied.
  CoreIndex::get_real_time_clock,
  CoreIndex::time_info,
  CoreIndex::seconds_since_epoch_local,

  // Remaining pure, process-local primitives.
  CoreIndex::raw_to_float,
  CoreIndex::raw32_to_float,
  CoreIndex::uint64_to_string,
  CoreIndex::printf_style_int64_to_string,
  CoreIndex::popcount,
  CoreIndex::int_vector_equals,
  CoreIndex::string_from_rune,
  CoreIndex::string_to_utf_16,
  CoreIndex::utf_16_to_string,
  CoreIndex::byte_array_is_valid_string_content,
  CoreIndex::crc,
  CoreIndex::word_size,       // BITS-PER-WORD; derivable from the smi range anyway.
  CoreIndex::platform,        // system.platform, LINE-TERMINATOR.
  CoreIndex::architecture,
  CoreIndex::gc_count,        // system.gc-count: waiting for a GC (finalizers).
  CoreIndex::main_arguments,
  CoreIndex::spawn_method,
  CoreIndex::spawn_arguments,
};

static const uint16 UNTRUSTED_BITMAP[] = {
  BitmapIndex::blit,
  BitmapIndex::byte_zap,
};

// Policy-owned tables for the partially allowed modules. Denied entries keep
// the arity of the real primitive, so the interpreter finds the arguments,
// but point to [primitive_denied].
static PrimitiveEntry untrusted_core_table[CORE_COUNT];
static PrimitiveEntry untrusted_bitmap_table[BITMAP_COUNT];

static Object* primitive_denied(Process* process, Object** arguments) {
  FAIL(PERMISSION_DENIED);
}

static void build_partial_table(PrimitiveEntry* table,
                                unsigned module,
                                unsigned count,
                                const uint16* allowed,
                                unsigned allowed_count) {
  for (unsigned i = 0; i < count; i++) {
    const PrimitiveEntry* original = Primitive::at(module, i);
    table[i].function = reinterpret_cast<void*>(primitive_denied);
    table[i].arity = original ? original->arity : 0;
  }
  for (unsigned i = 0; i < allowed_count; i++) {
    unsigned index = allowed[i];
    const PrimitiveEntry* original = Primitive::at(module, index);
    if (original != null) table[index] = *original;
  }
}

#ifdef TOIT_FREERTOS
static const word UNTRUSTED_MAX_HEAP_BYTES = 128 * KB;
static const word UNTRUSTED_MAX_MAILBOX_BYTES = 32 * KB;
static const word UNTRUSTED_MAX_MESSAGE_BYTES = 8 * KB;
#else
static const word UNTRUSTED_MAX_HEAP_BYTES = 64 * MB;
static const word UNTRUSTED_MAX_MAILBOX_BYTES = 1 * MB;
static const word UNTRUSTED_MAX_MESSAGE_BYTES = 256 * KB;
#endif

static const PolicyQuotas UNTRUSTED_QUOTAS = {
  UNTRUSTED_MAX_HEAP_BYTES,     // max_heap_bytes.
  256,                          // max_mailbox_messages.
  UNTRUSTED_MAX_MAILBOX_BYTES,  // max_mailbox_bytes.
  UNTRUSTED_MAX_MESSAGE_BYTES,  // max_message_bytes.
  64,                           // max_timers.
  1,                            // max_processes.
  2 * 1000 * 1000,              // max_run_time_us.
  0,                            // cpu_budget_us.
  64,                           // max_send_grants.
};

}  // namespace

PrimitivePolicy PrimitivePolicy::system_;
PrimitivePolicy PrimitivePolicy::trusted_;
PrimitivePolicy PrimitivePolicy::untrusted_;

void PrimitivePolicy::initialize_all(Kind kind) {
  kind_ = kind;
  owned_ = false;
  quotas_ = {};
  for (unsigned module = 0; module < Primitive::MODULE_COUNT; module++) {
    const PrimitiveEntry* table = Primitive::at(module, 0);
    tables_[module] = table;
    lengths_[module] = table ? Primitive::count(module) : 0;
  }
}

void PrimitivePolicy::initialize_untrusted() {
  kind_ = UNTRUSTED;
  owned_ = false;
  quotas_ = UNTRUSTED_QUOTAS;
  for (unsigned module = 0; module < Primitive::MODULE_COUNT; module++) {
    tables_[module] = null;
    lengths_[module] = 0;
  }

  build_partial_table(untrusted_core_table, MODULE_INDEX_core, CORE_COUNT,
                      UNTRUSTED_CORE, ARRAY_SIZE(UNTRUSTED_CORE));
  tables_[MODULE_INDEX_core] = untrusted_core_table;
  lengths_[MODULE_INDEX_core] = CORE_COUNT;

  if (Primitive::at(MODULE_INDEX_bitmap, 0) != null) {
    build_partial_table(untrusted_bitmap_table, MODULE_INDEX_bitmap, BITMAP_COUNT,
                        UNTRUSTED_BITMAP, ARRAY_SIZE(UNTRUSTED_BITMAP));
    tables_[MODULE_INDEX_bitmap] = untrusted_bitmap_table;
    lengths_[MODULE_INDEX_bitmap] = BITMAP_COUNT;
  }

  // The timer and events modules are allowed as a whole: sleep, timeouts and
  // monitors need them. Both only operate on resources the process owns.
  static const unsigned WHOLE_MODULES[] = { MODULE_INDEX_timer, MODULE_INDEX_events };
  for (unsigned i = 0; i < ARRAY_SIZE(WHOLE_MODULES); i++) {
    unsigned module = WHOLE_MODULES[i];
    const PrimitiveEntry* table = Primitive::at(module, 0);
    tables_[module] = table;
    lengths_[module] = table ? Primitive::count(module) : 0;
  }
}

void PrimitivePolicy::set_up() {
  static_assert(MODULE_INDEX_COUNT == Primitive::MODULE_COUNT, "Inconsistent module count");
  system_.initialize_all(SYSTEM);
  trusted_.initialize_all(TRUSTED);
  untrusted_.initialize_untrusted();
}

const PrimitivePolicy* PrimitivePolicy::launchable(int kind) {
  switch (kind) {
    case TRUSTED: return &trusted_;
    case UNTRUSTED: return &untrusted_;
    default: return null;
  }
}

bool PrimitivePolicy::may_send_type(int type) const {
  if (!restricts_messaging()) return true;
  if (type >= MESSAGING_RESERVED_MESSAGE_TYPES) return true;
  switch (type) {
    case SYSTEM_TRACE:
    case SYSTEM_RPC_REQUEST:
    case SYSTEM_RPC_REPLY:
    case SYSTEM_RPC_CANCEL:
    case SYSTEM_RPC_NOTIFY_RESOURCE:
      return true;
    default:
      return false;
  }
}

static bool read_quota(Array* array, int index, word* out, word scale, word max) {
  if (index >= array->length()) return true;
  Object* value = array->at(index);
  if (!is_smi(value)) return false;
  word v = Smi::value(value);
  if (v < 0) return true;  // Keep the default.
  if (v > max / scale) return false;
  *out = v * scale;
  return true;
}

const PrimitivePolicy* PrimitivePolicy::from_description(Object* description, Process* process, Object** error) {
  Program* program = process->program();
  *error = null;
  if (is_smi(description)) {
    const PrimitivePolicy* result = launchable(Smi::value(description));
    if (result == null) *error = Primitive::mark_as_error(program->invalid_argument());
    return result;
  }
  if (!is_array(description)) {
    *error = Primitive::mark_as_error(program->wrong_object_type());
    return null;
  }
  Array* array = Array::cast(description);
  if (array->length() < 1 || !is_smi(array->at(0))) {
    *error = Primitive::mark_as_error(program->invalid_argument());
    return null;
  }
  const PrimitivePolicy* base = launchable(Smi::value(array->at(0)));
  if (base == null) {
    *error = Primitive::mark_as_error(program->invalid_argument());
    return null;
  }
  PolicyQuotas quotas = base->quotas_;
  word run_time_ms = -1;
  word cpu_budget_ms = -1;
  const word MAX_WORD = Smi::MAX_SMI_VALUE;
  bool ok = read_quota(array, 1, &quotas.max_heap_bytes, 1, MAX_WORD)
      && read_quota(array, 2, &quotas.max_mailbox_messages, 1, MAX_WORD)
      && read_quota(array, 3, &quotas.max_mailbox_bytes, 1, MAX_WORD)
      && read_quota(array, 4, &quotas.max_message_bytes, 1, MAX_WORD)
      && read_quota(array, 5, &quotas.max_timers, 1, MAX_WORD)
      && read_quota(array, 6, &quotas.max_processes, 1, MAX_WORD)
      && read_quota(array, 7, &run_time_ms, 1, MAX_WORD)
      && read_quota(array, 8, &cpu_budget_ms, 1, MAX_WORD);
  if (!ok) {
    *error = Primitive::mark_as_error(program->out_of_range());
    return null;
  }
  if (run_time_ms >= 0) quotas.max_run_time_us = static_cast<int64>(run_time_ms) * 1000;
  if (cpu_budget_ms >= 0) quotas.cpu_budget_us = static_cast<int64>(cpu_budget_ms) * 1000;

  PrimitivePolicy* result = _new PrimitivePolicy();
  if (result == null) {
    *error = Primitive::mark_as_error(program->malloc_failed());
    return null;
  }
  *result = *base;
  result->owned_ = true;
  result->quotas_ = quotas;
  return result;
}

void PrimitivePolicy::release(const PrimitivePolicy* policy) {
  if (policy != null && policy->is_owned()) delete policy;
}

} // namespace toit

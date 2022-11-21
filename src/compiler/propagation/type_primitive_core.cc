// Copyright (C) 2022 Toitware ApS.
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

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(core, MODULE_CORE)

TYPE_PRIMITIVE_STRING(write_string_on_stdout)
TYPE_PRIMITIVE_STRING(write_string_on_stderr)

TYPE_PRIMITIVE_ANY(time)
TYPE_PRIMITIVE_ANY(time_info)
TYPE_PRIMITIVE_ANY(seconds_since_epoch_local)
TYPE_PRIMITIVE_ANY(set_tz)
TYPE_PRIMITIVE_ANY(platform)
TYPE_PRIMITIVE_ANY(process_stats)
TYPE_PRIMITIVE_ANY(bytes_allocated_delta)

TYPE_PRIMITIVE_SMI(string_length)
TYPE_PRIMITIVE_ANY(string_at)  // TODO(kasper): smi or null.
TYPE_PRIMITIVE_SMI(string_raw_at)
TYPE_PRIMITIVE_STRING(string_add)
TYPE_PRIMITIVE_STRING(string_slice)
TYPE_PRIMITIVE_ANY(int64_to_string)
TYPE_PRIMITIVE_ANY(printf_style_int64_to_string)
TYPE_PRIMITIVE_STRING(smi_to_string_base_10)
TYPE_PRIMITIVE_STRING(concat_strings)

TYPE_PRIMITIVE_SMI(array_length)
TYPE_PRIMITIVE_ANY(array_at)
TYPE_PRIMITIVE_ANY(array_at_put)
TYPE_PRIMITIVE_ARRAY(array_new)
TYPE_PRIMITIVE_ARRAY(array_expand)
TYPE_PRIMITIVE_NULL(array_replace)

TYPE_PRIMITIVE_ANY(list_add)

TYPE_PRIMITIVE_ANY(compare_to)
TYPE_PRIMITIVE_ANY(min_special_compare_to)
TYPE_PRIMITIVE_ANY(string_compare)
TYPE_PRIMITIVE_ANY(string_rune_count)

TYPE_PRIMITIVE_BOOL(identical)
TYPE_PRIMITIVE_BOOL(object_equals)
TYPE_PRIMITIVE_BOOL(blob_equals)

TYPE_PRIMITIVE_ANY(random)
TYPE_PRIMITIVE_ANY(random_seed)
TYPE_PRIMITIVE_ANY(add_entropy)
TYPE_PRIMITIVE_ANY(count_leading_zeros)
TYPE_PRIMITIVE_ANY(popcount)
TYPE_PRIMITIVE_ANY(put_uint_big_endian)
TYPE_PRIMITIVE_ANY(read_int_big_endian)
TYPE_PRIMITIVE_ANY(read_uint_big_endian)
TYPE_PRIMITIVE_ANY(put_uint_little_endian)
TYPE_PRIMITIVE_ANY(read_int_little_endian)
TYPE_PRIMITIVE_ANY(read_uint_little_endian)
TYPE_PRIMITIVE_ANY(put_float_64_little_endian)
TYPE_PRIMITIVE_ANY(put_float_32_little_endian)

TYPE_PRIMITIVE_SMI(smi_not)
TYPE_PRIMITIVE_SMI(smi_shift_right)

TYPE_PRIMITIVE_INT(smi_unary_minus)
TYPE_PRIMITIVE_INT(smi_and)
TYPE_PRIMITIVE_INT(smi_or)
TYPE_PRIMITIVE_INT(smi_xor)
TYPE_PRIMITIVE_INT(smi_add)
TYPE_PRIMITIVE_INT(smi_subtract)
TYPE_PRIMITIVE_INT(smi_multiply)
TYPE_PRIMITIVE_INT(smi_divide)
TYPE_PRIMITIVE_INT(smi_mod)
TYPE_PRIMITIVE_INT(smi_unsigned_shift_right)
TYPE_PRIMITIVE_INT(smi_shift_left)

TYPE_PRIMITIVE_INT(large_integer_unary_minus)
TYPE_PRIMITIVE_INT(large_integer_not)
TYPE_PRIMITIVE_INT(large_integer_and)
TYPE_PRIMITIVE_INT(large_integer_or)
TYPE_PRIMITIVE_INT(large_integer_xor)
TYPE_PRIMITIVE_INT(large_integer_shift_right)
TYPE_PRIMITIVE_INT(large_integer_unsigned_shift_right)
TYPE_PRIMITIVE_INT(large_integer_shift_left)
TYPE_PRIMITIVE_INT(large_integer_add)
TYPE_PRIMITIVE_INT(large_integer_subtract)
TYPE_PRIMITIVE_INT(large_integer_multiply)
TYPE_PRIMITIVE_INT(large_integer_divide)
TYPE_PRIMITIVE_INT(large_integer_mod)

TYPE_PRIMITIVE_FLOAT(float_unary_minus)
TYPE_PRIMITIVE_FLOAT(float_add)
TYPE_PRIMITIVE_FLOAT(float_subtract)
TYPE_PRIMITIVE_FLOAT(float_multiply)
TYPE_PRIMITIVE_FLOAT(float_divide)
TYPE_PRIMITIVE_FLOAT(float_mod)
TYPE_PRIMITIVE_FLOAT(float_round)
TYPE_PRIMITIVE_FLOAT(float_sqrt)
TYPE_PRIMITIVE_FLOAT(float_ceil)
TYPE_PRIMITIVE_FLOAT(float_floor)
TYPE_PRIMITIVE_FLOAT(float_trunc)

TYPE_PRIMITIVE_SMI(float_sign)
TYPE_PRIMITIVE_BOOL(float_is_nan)
TYPE_PRIMITIVE_BOOL(float_is_finite)

TYPE_PRIMITIVE_INT(int_parse)
TYPE_PRIMITIVE_FLOAT(float_parse)

TYPE_PRIMITIVE_BOOL(smi_equals)
TYPE_PRIMITIVE_BOOL(smi_less_than)
TYPE_PRIMITIVE_BOOL(smi_less_than_or_equal)
TYPE_PRIMITIVE_BOOL(smi_greater_than)
TYPE_PRIMITIVE_BOOL(smi_greater_than_or_equal)

TYPE_PRIMITIVE_BOOL(large_integer_equals)
TYPE_PRIMITIVE_BOOL(large_integer_less_than)
TYPE_PRIMITIVE_BOOL(large_integer_less_than_or_equal)
TYPE_PRIMITIVE_BOOL(large_integer_greater_than)
TYPE_PRIMITIVE_BOOL(large_integer_greater_than_or_equal)

TYPE_PRIMITIVE_BOOL(float_equals)
TYPE_PRIMITIVE_BOOL(float_less_than)
TYPE_PRIMITIVE_BOOL(float_less_than_or_equal)
TYPE_PRIMITIVE_BOOL(float_greater_than)
TYPE_PRIMITIVE_BOOL(float_greater_than_or_equal)

TYPE_PRIMITIVE_SMI(object_class_id)
TYPE_PRIMITIVE_SMI(string_hash_code)
TYPE_PRIMITIVE_SMI(blob_hash_code)

TYPE_PRIMITIVE_ANY(hash_simple_json_string)
TYPE_PRIMITIVE_ANY(compare_simple_json_string)
TYPE_PRIMITIVE_ANY(size_of_json_number)
TYPE_PRIMITIVE_ANY(json_skip_whitespace)

TYPE_PRIMITIVE_BOOL(task_has_messages)
TYPE_PRIMITIVE_ANY(task_receive_message)
TYPE_PRIMITIVE_TASK(task_current)
TYPE_PRIMITIVE_TASK(task_new)
TYPE_PRIMITIVE_SMI(task_transfer)
TYPE_PRIMITIVE_ANY(task_stack)  // TODO(kasper): Can we get rid of this?

TYPE_PRIMITIVE_ANY(float_to_string)
TYPE_PRIMITIVE_ANY(float_to_raw)
TYPE_PRIMITIVE_ANY(raw_to_float)
TYPE_PRIMITIVE_ANY(float_to_raw32)
TYPE_PRIMITIVE_ANY(raw32_to_float)

TYPE_PRIMITIVE_INT(number_to_integer)
TYPE_PRIMITIVE_FLOAT(number_to_float)

TYPE_PRIMITIVE_BYTE_ARRAY(encode_error)

TYPE_PRIMITIVE_ANY(command)
TYPE_PRIMITIVE_ANY(main_arguments)
TYPE_PRIMITIVE_ANY(spawn)
TYPE_PRIMITIVE_ANY(spawn_method)
TYPE_PRIMITIVE_ANY(spawn_arguments)
TYPE_PRIMITIVE_ANY(get_generic_resource_group)
TYPE_PRIMITIVE_ANY(process_signal_kill)
TYPE_PRIMITIVE_ANY(process_current_id)
TYPE_PRIMITIVE_ANY(process_send)
TYPE_PRIMITIVE_ANY(process_get_priority)
TYPE_PRIMITIVE_ANY(process_set_priority)
TYPE_PRIMITIVE_ANY(gc_count)
TYPE_PRIMITIVE_ANY(byte_array_is_raw_bytes)
TYPE_PRIMITIVE_ANY(byte_array_length)
TYPE_PRIMITIVE_ANY(byte_array_at)
TYPE_PRIMITIVE_ANY(byte_array_at_put)
TYPE_PRIMITIVE_ANY(byte_array_new)
TYPE_PRIMITIVE_ANY(byte_array_new_external)
TYPE_PRIMITIVE_ANY(byte_array_replace)
TYPE_PRIMITIVE_ANY(byte_array_is_valid_string_content)
TYPE_PRIMITIVE_ANY(byte_array_convert_to_string)
TYPE_PRIMITIVE_ANY(blob_index_of)
TYPE_PRIMITIVE_ANY(crc)
TYPE_PRIMITIVE_ANY(string_from_rune)
TYPE_PRIMITIVE_ANY(string_write_to_byte_array)
TYPE_PRIMITIVE_ANY(create_off_heap_byte_array)
TYPE_PRIMITIVE_ANY(add_finalizer)
TYPE_PRIMITIVE_ANY(remove_finalizer)
TYPE_PRIMITIVE_ANY(vm_sdk_version)
TYPE_PRIMITIVE_ANY(vm_sdk_info)
TYPE_PRIMITIVE_ANY(vm_sdk_model)
TYPE_PRIMITIVE_ANY(app_sdk_version)
TYPE_PRIMITIVE_ANY(app_sdk_info)
TYPE_PRIMITIVE_ANY(encode_object)
TYPE_PRIMITIVE_ANY(rebuild_hash_index)
TYPE_PRIMITIVE_ANY(profiler_install)
TYPE_PRIMITIVE_ANY(profiler_start)
TYPE_PRIMITIVE_ANY(profiler_stop)
TYPE_PRIMITIVE_ANY(profiler_encode)
TYPE_PRIMITIVE_ANY(profiler_uninstall)
TYPE_PRIMITIVE_ANY(set_max_heap_size)
TYPE_PRIMITIVE_ANY(get_real_time_clock)
TYPE_PRIMITIVE_ANY(set_real_time_clock)
TYPE_PRIMITIVE_ANY(get_system_time)
TYPE_PRIMITIVE_ANY(debug_set_memory_limit)
TYPE_PRIMITIVE_ANY(dump_heap)
TYPE_PRIMITIVE_ANY(serial_print_heap_report)
TYPE_PRIMITIVE_ANY(get_env)
TYPE_PRIMITIVE_ANY(literal_index)
TYPE_PRIMITIVE_ANY(word_size)
TYPE_PRIMITIVE_ANY(firmware_map)
TYPE_PRIMITIVE_ANY(firmware_unmap)
TYPE_PRIMITIVE_ANY(firmware_mapping_at)
TYPE_PRIMITIVE_ANY(firmware_mapping_copy)

}  // namespace toit::compiler
}  // namespace toit

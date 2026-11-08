#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""
Generates tests/fuzz/primitives.toit: one wrapper per fuzzed primitive.

The fuzzed set is the allowed (pure, process-local) set of the server
primitive policy (sandboxing report 05, section 1), minus the primitives
listed in SKIPPED. Every name is checked against src/primitive.h, so the
generator fails if a primitive is renamed or removed.

Usage: tests/fuzz/gen-primitive-fuzz.py > tests/fuzz/primitives.toit
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")

CORE_ALLOWED = """
string_length string_at string_raw_at string_add string_slice string_compare
string_rune_count string_hash_code string_from_rune string_write_to_byte_array
string_to_utf_16 utf_16_to_string concat_strings
array_length array_at array_at_put array_new array_expand array_replace list_add
rebuild_hash_index
byte_array_is_raw_bytes byte_array_length byte_array_at byte_array_at_put
byte_array_new byte_array_new_external byte_array_replace
byte_array_is_valid_string_content byte_array_convert_to_string blob_equals
blob_hash_code blob_index_of int_vector_equals create_off_heap_byte_array crc
smi_unary_minus smi_not smi_and smi_or smi_xor smi_add smi_subtract smi_multiply
smi_divide smi_mod smi_less_than smi_less_than_or_equal smi_greater_than
smi_greater_than_or_equal smi_equals smi_shift_right smi_unsigned_shift_right
smi_shift_left smi_to_string_base_10
large_integer_unary_minus large_integer_not large_integer_and large_integer_or
large_integer_xor large_integer_shift_right large_integer_unsigned_shift_right
large_integer_shift_left large_integer_add large_integer_subtract
large_integer_multiply large_integer_divide large_integer_mod
large_integer_equals large_integer_less_than large_integer_less_than_or_equal
large_integer_greater_than large_integer_greater_than_or_equal
float_unary_minus float_add float_subtract float_multiply float_divide float_mod
float_round float_parse float_sign float_is_nan float_is_finite float_less_than
float_less_than_or_equal float_greater_than float_greater_than_or_equal
float_equals float_to_string float_to_raw float_to_raw32 float_sqrt float_ceil
float_floor float_trunc raw_to_float raw32_to_float
int64_to_string uint64_to_string printf_style_int64_to_string compare_to
min_special_compare_to number_to_float number_to_integer int_parse
count_leading_zeros popcount
put_uint_big_endian read_int_big_endian read_uint_big_endian
put_uint_little_endian read_int_little_endian read_uint_little_endian
put_float_64_little_endian put_float_32_little_endian
hash_simple_json_string compare_simple_json_string size_of_json_number
json_skip_whitespace
object_class_id literal_index encode_object encode_error word_size
random random_seed
time time_info seconds_since_epoch_local get_real_time_clock
platform architecture vm_sdk_version vm_sdk_info vm_sdk_model app_sdk_version
app_sdk_info program_name
process_current_id process_system_id task_has_messages task_receive_message
task_new task_transfer gc_count bytes_allocated_delta add_finalizer
remove_finalizer get_generic_resource_group main_arguments spawn_method
spawn_arguments
"""

# Whole modules that are allowed (report 05, section 1.2, plus bitmap/font,
# which are pure).
MODULES_ALLOWED = ["timer", "events", "encoding", "math", "bignum", "crypto",
                   "crypto_random", "zlib", "x509", "bitmap", "font"]

# Allowed, but not fuzzed with random arguments.
SKIPPED = {
  # Task switching: random arguments would switch to arbitrary tasks or
  # block the driver (the primitives check their argument types).
  ("core", "task_new"): "creates and schedules tasks running random code",
  ("core", "task_transfer"): "switches to another task",
  ("core", "task_receive_message"): "consumes the driver's messages",
  # CPU-heavy (seconds per call); need the CPU budget, not fuzzing.
  ("crypto", "rsa_generate"): "CPU-heavy key generation",
  ("crypto", "ec_generate_key"): "CPU-heavy key generation",
}

def parse_primitives():
  text = open(os.path.join(ROOT, "src", "primitive.h")).read()
  modules = {}
  for match in re.finditer(r"#define (MODULE_[A-Z0-9_]+)\(PRIMITIVE\)((?:.*\\\n)+)", text):
    entries = re.findall(r"PRIMITIVE\((\w+),\s*(\d+)\)", match.group(2))
    modules[match.group(1)] = [(name, int(arity)) for name, arity in entries]
  names = dict(re.findall(r"M\((\w+),\s*(MODULE_[A-Z0-9_]+)\)", text))
  result = {}
  for module, macro in names.items():
    result[module] = modules.get(macro, [])
  return result

def kebab(name):
  return name.replace("_", "-")

def main():
  primitives = parse_primitives()
  selected = []
  skipped = []
  core = dict(primitives["core"])
  for name in CORE_ALLOWED.split():
    if name not in core:
      sys.exit("unknown core primitive: " + name)
    selected.append(("core", name, core[name]))
  for module in MODULES_ALLOWED:
    if module not in primitives: sys.exit("unknown module: " + module)
    for name, arity in primitives[module]:
      selected.append((module, name, arity))
  out = []
  out.append("// Copyright (C) 2026 Toit contributors.")
  out.append("// Use of this source code is governed by a Zero-Clause BSD license that can")
  out.append("// be found in the tests/LICENSE file.")
  out.append("")
  out.append("// Generated by tests/fuzz/gen-primitive-fuzz.py. Do not edit.")
  out.append("")
  entries = []
  for module, name, arity in selected:
    key = (module, name)
    is_skipped = any(key[0] == s[0] and key[1].startswith(s[1]) for s in SKIPPED)
    if is_skipped:
      skipped.append(key)
      continue
    wrapper = "prim-%s-%s" % (kebab(module), kebab(name))
    params = " ".join("a%d" % i for i in range(arity))
    out.append("%s%s:" % (wrapper, (" " + params) if params else ""))
    out.append("  #primitive.%s.%s" % (kebab(module), kebab(name)))
    out.append("")
    entries.append((module, name, arity, wrapper))
  out.append("/// Number of fuzzed primitives.")
  out.append("PRIMITIVE-COUNT ::= %d" % len(entries))
  out.append("")
  out.append("/// Names of the fuzzed primitives (module.name).")
  out.append("PRIMITIVE-NAMES ::= [")
  for module, name, arity, wrapper in entries:
    out.append('  "%s.%s",' % (module, name))
  out.append("]")
  out.append("")
  out.append("/// Arities of the fuzzed primitives.")
  out.append("PRIMITIVE-ARITIES ::= [")
  for module, name, arity, wrapper in entries:
    out.append("  %d," % arity)
  out.append("]")
  out.append("")
  out.append("/// Skipped (allowed but not fuzzed): %s." % ", ".join("%s.%s" % k for k in skipped))
  out.append("call-primitive index/int args/List -> any:")
  for i, (module, name, arity, wrapper) in enumerate(entries):
    args = " ".join("args[%d]" % j for j in range(arity))
    out.append("  if index == %d: return %s%s" % (i, wrapper, (" " + args) if args else ""))
  out.append("  unreachable")
  print("\n".join(out))

main()

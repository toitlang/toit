// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Generates tests/fuzz/primitives.toit: one wrapper per fuzzed primitive.

The fuzzed set is the allowed (pure, process-local) set of the server
  primitive policy (sandboxing report 05, section 1), minus the primitives
  listed in $SKIPPED. Every name is checked against src/primitive.h, so the
  generator fails if a primitive is renamed or removed.

Usage: toit run tests/fuzz/gen-primitive-fuzz.toit > tests/fuzz/primitives.toit
*/

import fs
import host.file
import host.pipe
import system

ROOT ::= fs.clean (fs.join (fs.dirname system.program-path) ".." "..")

CORE-ALLOWED ::= """
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
process_current_id process_system_id process_send task_has_messages task_receive_message
task_new task_transfer gc_count bytes_allocated_delta add_finalizer
remove_finalizer get_generic_resource_group main_arguments spawn_method
spawn_arguments
"""

MODULES-ALLOWED ::= ["timer", "events", "encoding", "math", "bignum", "crypto",
                     "crypto_random", "zlib", "x509", "bitmap", "font"]

/**
Allowed primitives that are not fuzzed: [module, name prefix, reason].
*/
SKIPPED ::= [
  // Task switching: random arguments would switch to arbitrary tasks or
  // block the driver (the primitives check their argument types).
  ["core", "task_new", "creates and schedules tasks running random code"],
  ["core", "task_transfer", "switches to another task"],
  ["core", "task_receive_message", "consumes the driver's messages"],
  // CPU-heavy (seconds per call); need the CPU budget, not fuzzing.
  ["crypto", "rsa_generate", "CPU-heavy key generation"],
  ["crypto", "ec_generate_key", "CPU-heavy key generation"],
]

is-word-char_ c/int? -> bool:
  if c == null: return false
  return 'a' <= c <= 'z' or 'A' <= c <= 'Z' or '0' <= c <= '9' or c == '_'

char-at_ text/string i/int -> int?:
  return i < text.size ? text.at --raw i : null

/**
Returns the [name, arity] pairs of the `PRIMITIVE(<name>, <arity>)` entries
  in $text.
*/
find-primitives text/string -> List:
  result := []
  from := 0
  while true:
    at := text.index-of "PRIMITIVE(" from
    if at < 0: break
    from = at + 1
    i := at + 10
    start := i
    while is-word-char_ (char-at_ text i): i++
    if i == start or (char-at_ text i) != ',': continue
    name := text[start..i]
    i++
    while (char-at_ text i) == ' ' or (char-at_ text i) == '\t' or (char-at_ text i) == '\n': i++
    digits := i
    while '0' <= ((char-at_ text i) or 0) <= '9': i++
    if i == digits or (char-at_ text i) != ')': continue
    result.add [name, int.parse text[digits..i]]
  return result

/**
Maps each module name of `MODULES(M)` to its [name, arity] pairs. A module's
  primitives are on the backslash-continued lines of its
  `#define <MACRO>(PRIMITIVE)`.
*/
parse-primitives -> Map:
  text := (file.read-contents (fs.join ROOT "src" "primitive.h")).to-string
  lines := text.split "\n"
  // The macro bodies.
  modules := {:}
  lines.size.repeat: | index |
    line/string := lines[index]
    at := line.index-of "#define MODULE_"
    if at < 0: continue.repeat
    i := at + 8
    start := i
    while is-word-char_ (char-at_ line i) and not 'a' <= (char-at_ line i) <= 'z': i++
    macro := line[start..i]
    if not line[i..].starts-with "(PRIMITIVE)": continue.repeat
    // The rest of this line and the following lines, as long as they end
    // with a backslash.
    body := []
    rest := line[i + 11..]
    j := index
    while rest.ends-with "\\" and j + 1 <= lines.size:
      body.add rest
      j++
      if j >= lines.size: break
      rest = lines[j]
    if body.is-empty: continue.repeat
    modules[macro] = find-primitives (body.join "\n")
  // The module names, in the order of MODULES(M).
  result := {:}
  from := 0
  while true:
    at := text.index-of "M(" from
    if at < 0: break
    from = at + 1
    i := at + 2
    start := i
    while is-word-char_ (char-at_ text i): i++
    if i == start or (char-at_ text i) != ',': continue
    name := text[start..i]
    i++
    while (char-at_ text i) == ' ' or (char-at_ text i) == '\t' or (char-at_ text i) == '\n': i++
    if not text[i..].starts-with "MODULE_": continue
    macro-start := i
    i += 7
    while is-word-char_ (char-at_ text i) and not 'a' <= (char-at_ text i) <= 'z': i++
    if (char-at_ text i) != ')': continue
    result[name] = modules.get text[macro-start..i] --if-absent=: []
  return result

kebab name/string -> string:
  return name.replace --all "_" "-"

fail message/string -> none:
  pipe.print-to-stderr message
  exit 1

main:
  primitives := parse-primitives
  selected := []
  skipped := []
  core := {:}
  primitives["core"].do: core[it[0]] = it[1]
  (CORE-ALLOWED.split "\n").do: | line |
    (line.split " ").do: | name |
      if name == "": continue.do
      if not core.contains name: fail "unknown core primitive: $name"
      selected.add ["core", name, core[name]]
  MODULES-ALLOWED.do: | module |
    if not primitives.contains module: fail "unknown module: $module"
    primitives[module].do: | entry |
      selected.add [module, entry[0], entry[1]]
  out := []
  out.add "// Copyright (C) 2026 Toit contributors."
  out.add "// Use of this source code is governed by a Zero-Clause BSD license that can"
  out.add "// be found in the tests/LICENSE file."
  out.add ""
  out.add "// Generated by tests/fuzz/gen-primitive-fuzz.toit. Do not edit."
  out.add ""
  entries := []
  selected.do: | entry |
    module/string := entry[0]
    name/string := entry[1]
    arity/int := entry[2]
    is-skipped := SKIPPED.any: module == it[0] and name.starts-with it[1]
    if is-skipped:
      skipped.add "$module.$name"
      continue.do
    wrapper := "prim-$(kebab module)-$(kebab name)"
    params := (List arity: "a$it").join " "
    out.add "$wrapper$(params.is-empty ? "" : " " + params):"
    out.add "  #primitive.$(kebab module).$(kebab name)"
    out.add ""
    entries.add [module, name, arity, wrapper]
  out.add "/// Number of fuzzed primitives."
  out.add "PRIMITIVE-COUNT ::= $entries.size"
  out.add ""
  out.add "/// Names of the fuzzed primitives (module.name)."
  out.add "PRIMITIVE-NAMES ::= ["
  entries.do: out.add "  \"$it[0].$it[1]\","
  out.add "]"
  out.add ""
  out.add "/// Arities of the fuzzed primitives."
  out.add "PRIMITIVE-ARITIES ::= ["
  entries.do: out.add "  $it[2],"
  out.add "]"
  out.add ""
  out.add "/// Skipped (allowed but not fuzzed): $(skipped.join ", ")."
  out.add "call-primitive index/int args/List -> any:"
  entries.size.repeat: | i |
    entry := entries[i]
    args := (List entry[2]: "args[$it]").join " "
    out.add "  if index == $i: return $entry[3]$(args.is-empty ? "" : " " + args)"
  out.add "  unreachable"
  print (out.join "\n")

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Differential driver for the Rust ports of the primitives
(verified/core/src/prims): calls the ported primitives with the random
arguments of primitive-fuzz.toit and prints a running checksum of every
result, thrown error and argument afterwards (arguments are mutated by
some primitives). Run it in format 2 once trusted without verification (the
core's checked loop calls the C++ primitives) and once untrusted (the
verified loop runs the Rust ports) and compare the outputs;
verified/core/tests/prim_diff.sh does that.

Usage: primitive-diff.toit <seed> <iterations> [<trace-from> [<trace-to>]]

With a trace range every call in it is printed with its description.
*/

import .primitives

// The ported primitives (deterministic: no time, random, GC counters).
PORTED ::= {
  "core.string_length", "core.string_at", "core.string_raw_at", "core.string_add",
  "core.string_slice", "core.string_compare", "core.string_rune_count",
  "core.string_hash_code", "core.string_write_to_byte_array", "core.concat_strings",
  "core.array_length", "core.array_at", "core.array_at_put", "core.array_new",
  "core.array_expand", "core.array_replace", "core.list_add", "core.rebuild_hash_index",
  "core.byte_array_is_raw_bytes", "core.byte_array_length", "core.byte_array_at",
  "core.byte_array_at_put", "core.byte_array_new", "core.byte_array_replace",
  "core.blob_equals", "core.blob_hash_code", "core.blob_index_of",
  "core.smi_unary_minus", "core.smi_not", "core.smi_and", "core.smi_or", "core.smi_xor",
  "core.smi_add", "core.smi_subtract", "core.smi_multiply", "core.smi_divide", "core.smi_mod",
  "core.smi_less_than", "core.smi_less_than_or_equal", "core.smi_greater_than",
  "core.smi_greater_than_or_equal", "core.smi_equals", "core.smi_shift_right",
  "core.smi_unsigned_shift_right", "core.smi_shift_left",
  "core.large_integer_unary_minus", "core.large_integer_not", "core.large_integer_and",
  "core.large_integer_or", "core.large_integer_xor", "core.large_integer_shift_right",
  "core.large_integer_unsigned_shift_right", "core.large_integer_shift_left",
  "core.large_integer_add", "core.large_integer_subtract", "core.large_integer_multiply",
  "core.large_integer_divide", "core.large_integer_mod", "core.large_integer_equals",
  "core.large_integer_less_than", "core.large_integer_less_than_or_equal",
  "core.large_integer_greater_than", "core.large_integer_greater_than_or_equal",
  "core.float_unary_minus", "core.float_add", "core.float_subtract", "core.float_multiply",
  "core.float_divide", "core.float_mod", "core.float_sign", "core.float_is_nan",
  "core.float_is_finite", "core.float_less_than", "core.float_less_than_or_equal",
  "core.float_greater_than", "core.float_greater_than_or_equal", "core.float_equals",
  "core.float_to_raw", "core.float_to_raw32", "core.float_sqrt", "core.float_ceil",
  "core.float_floor", "core.float_trunc", "core.raw_to_float", "core.raw32_to_float",
  "core.compare_to", "core.min_special_compare_to", "core.number_to_float",
  "core.number_to_integer", "core.count_leading_zeros", "core.popcount",
  "core.hash_simple_json_string", "core.compare_simple_json_string",
  "core.size_of_json_number", "core.json_skip_whitespace", "core.object_class_id",
  "core.read_int_big_endian", "core.read_uint_big_endian", "core.read_int_little_endian",
  "core.read_uint_little_endian", "core.put_uint_big_endian", "core.put_uint_little_endian",
  "core.put_float_64_little_endian", "core.put_float_32_little_endian",
  "core.int_vector_equals", "core.string_from_rune",
}

class Rng:
  state_/int := ?

  constructor seed/int:
    state_ = seed == 0 ? 0x1234_5678 : seed

  next -> int:
    x := state_
    x ^= x >>> 12
    x ^= x << 25
    x ^= x >>> 27
    state_ = x
    return (x * 0x2545F4914F6CDD1D) >>> 1

  next max/int -> int:
    return next % max

class Point:
  x := 1
  y := "y"
  constructor:
  constructor .x .y:

interesting-ints ::= [
  0, 1, -1, 2, 3, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256,
  1000, 4096, 65535, 65536, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff,
  0x1_0000_0000, 0x3fff_ffff, -(0x3fff_ffff) - 1,
  0x3fff_ffff_ffff_ffff, -(0x3fff_ffff_ffff_ffff) - 1,
  0x4000_0000_0000_0000, 0x7fff_ffff_ffff_ffff, int.MIN, int.MIN + 1,
  -2, -8, -64, -65, -256,
]

interesting-floats ::= [
  0.0, -0.0, 0.5, 1.0, -1.5, 3.14159, 1e10, 1e300, -1e300, 1e-300, 5e-324,
  float.MAX-FINITE, float.MIN-POSITIVE, float.INFINITY, -float.INFINITY,
  float.NAN, 9.2233720368547758e18, -9.2233720368547758e18, 4503599627370497.0,
]

big-string ::= "x" * 70_000

MAX-SIZE ::= 1 << 16

make-pool rng/Rng -> List:
  pool := []
  pool.add-all interesting-ints
  pool.add-all interesting-floats
  10.repeat: pool.add (rng.next - (rng.next))
  10.repeat: pool.add (rng.next 100) - 50
  pool.add-all [null, true, false]
  pool.add-all [
    "", "a", "hello world", "ünïcödé €", "\x00\x01\xff",
    "12345", "-42", "0x1f", "1e10", "nan", "  3.5  ", "[1, 2]", "\"json\"",
    "x" * 1000, big-string, "hello world"[2..7], big-string[100..200],
    "\"key\": 12.5e3, ", "  \t\n 17]", "€𝄞", "a\\\"b\"",
  ]
  pool.add-all [
    #[], #[0], #[1, 2, 3], #[0xff, 0xfe, 0xfd, 0xfc, 0xfb, 0xfa, 0xf9, 0xf8],
    ByteArray 16, ByteArray 100: it, ByteArray 5000: it * 7,
    (ByteArray 100: it)[10..20], "abc".to-byte-array,
    #[0x7b, 0x7d], ByteArray 1, ByteArray 33: 0xff, #[0x22, 0x61, 0x22][1..],
    (ByteArray 50: it)[5..40][3..20],
  ]
  pool.add-all [
    [], [1, 2, 3], ["a", "b"], List 100: it, ["ab", "cd"[0..1], "é"],
    [1.5, null, "x", #[1]], ([1, 2, 3, 4, 5])[1..3], Array_ 8 0, Array_ 16 0, Array_ 3 7,
    Array_ 4 "ab", Array_ 32 0, Array_ 10 (2 * 9 + 1),
  ]
  strings := Array_ 4 ""
  strings[0] = "one"
  strings[1] = "zwei"[1..3]
  strings[2] = "€"
  strings[3] = big-string[0..300]
  pool.add strings
  pool.add-all [
    {:}, {"a": 1, "b": 2}, {1: 2}, {"x"}, {1, 2, 3},
  ]
  pool.add-all [
    Point, Point 5 "five", (:: it), (:: 42), Exception_ "x" null,
  ]
  return pool

random-argument rng/Rng pool/List -> any:
  choice := rng.next 10
  if choice == 0: return interesting-ints[rng.next interesting-ints.size]
  if choice == 1: return rng.next 64
  return pool[rng.next pool.size]

/**
Argument types for typed calls (half of the calls), so that the success
  paths are exercised too: i int, n small int (an index or length), L large
  int, f float, s string (or slice), B byte array (or slice), b string or
  byte array, a array, S array of strings, l list, x anything.
*/
SIGNATURES ::= {
  "core.string_length": "s", "core.string_at": "sn", "core.string_raw_at": "sn",
  "core.string_add": "ss", "core.string_slice": "snn", "core.string_compare": "ss",
  "core.string_rune_count": "b", "core.string_hash_code": "s",
  "core.string_write_to_byte_array": "bBnnn", "core.concat_strings": "S",
  "core.array_length": "a", "core.array_at": "an", "core.array_at_put": "anx",
  "core.array_new": "nx", "core.array_expand": "annx", "core.array_replace": "anann",
  "core.list_add": "lx", "core.rebuild_hash_index": "aa",
  "core.byte_array_is_raw_bytes": "B", "core.byte_array_length": "B",
  "core.byte_array_at": "Bn", "core.byte_array_at_put": "Bni", "core.byte_array_new": "ni",
  "core.byte_array_replace": "Bnbnn", "core.blob_equals": "bb", "core.blob_hash_code": "b",
  "core.blob_index_of": "bnnn",
  "core.smi_unary_minus": "i", "core.smi_not": "i", "core.smi_and": "ii", "core.smi_or": "ii",
  "core.smi_xor": "ii", "core.smi_add": "ii", "core.smi_subtract": "ii", "core.smi_multiply": "ii",
  "core.smi_divide": "ii", "core.smi_mod": "ii", "core.smi_less_than": "ii",
  "core.smi_less_than_or_equal": "ii", "core.smi_greater_than": "ii",
  "core.smi_greater_than_or_equal": "ii", "core.smi_equals": "ii", "core.smi_shift_right": "in",
  "core.smi_unsigned_shift_right": "in", "core.smi_shift_left": "in",
  "core.large_integer_unary_minus": "L", "core.large_integer_not": "L",
  "core.large_integer_and": "Li", "core.large_integer_or": "Li", "core.large_integer_xor": "Li",
  "core.large_integer_shift_right": "Ln", "core.large_integer_unsigned_shift_right": "Ln",
  "core.large_integer_shift_left": "Ln", "core.large_integer_add": "Li",
  "core.large_integer_subtract": "Li", "core.large_integer_multiply": "Li",
  "core.large_integer_divide": "Li", "core.large_integer_mod": "Li",
  "core.large_integer_equals": "Li", "core.large_integer_less_than": "Li",
  "core.large_integer_less_than_or_equal": "Li", "core.large_integer_greater_than": "Li",
  "core.large_integer_greater_than_or_equal": "Li",
  "core.float_unary_minus": "f", "core.float_add": "ff", "core.float_subtract": "ff",
  "core.float_multiply": "ff", "core.float_divide": "ff", "core.float_mod": "ff",
  "core.float_sign": "f", "core.float_is_nan": "f", "core.float_is_finite": "f",
  "core.float_less_than": "ff", "core.float_less_than_or_equal": "ff",
  "core.float_greater_than": "ff", "core.float_greater_than_or_equal": "ff",
  "core.float_equals": "ff", "core.float_to_raw": "f", "core.float_to_raw32": "f",
  "core.float_sqrt": "f", "core.float_ceil": "f", "core.float_floor": "f", "core.float_trunc": "f",
  "core.raw_to_float": "i", "core.raw32_to_float": "i", "core.compare_to": "xx",
  "core.min_special_compare_to": "xx", "core.number_to_float": "x", "core.number_to_integer": "x",
  "core.count_leading_zeros": "i", "core.popcount": "i",
  "core.hash_simple_json_string": "bn", "core.compare_simple_json_string": "bns",
  "core.size_of_json_number": "bn", "core.json_skip_whitespace": "bn",
  "core.object_class_id": "x",
  "core.read_int_big_endian": "xbnn", "core.read_uint_big_endian": "xbnn",
  "core.read_int_little_endian": "xbnn", "core.read_uint_little_endian": "xbnn",
  "core.put_uint_big_endian": "xBnni", "core.put_uint_little_endian": "xBnni",
  "core.put_float_64_little_endian": "xBnf", "core.put_float_32_little_endian": "xBnf",
  "core.int_vector_equals": "ii", "core.string_from_rune": "r",
}

large-ints ::= [
  0x4000_0000_0000_0000, 0x7fff_ffff_ffff_ffff, int.MIN, int.MIN + 1,
  -(0x3fff_ffff_ffff_ffff) - 2, 0x4000_0000_0000_0001, 0x5555_5555_5555_5555,
]

typed-argument rng/Rng pool/List type/int -> any:
  if type == 'x': return random-argument rng pool
  if type == 'n': return (rng.next 72) - 3
  if type == 'r':
    c := rng.next 3
    if c == 0: return rng.next 0x80
    if c == 1: return rng.next 0x800
    return (rng.next 0x11_0010) - 8
  if type == 'i':
    c := rng.next 3
    if c == 0: return interesting-ints[rng.next interesting-ints.size]
    if c == 1: return (rng.next 200) - 100
    return rng.next - (rng.next)
  if type == 'L': return large-ints[rng.next large-ints.size]
  if type == 'f':
    if (rng.next 2) == 0: return interesting-floats[rng.next interesting-floats.size]
    return ((rng.next 2000) - 1000) / 7.0
  // Pick from the pool by type.
  20.repeat:
    v := pool[rng.next pool.size]
    if type == 's' and v is string: return v
    if type == 'B' and v is ByteArray: return v
    if type == 'b' and (v is string or v is ByteArray): return v
    if type == 'a' and v is Array_: return v
    if type == 'l' and v is List and v is not Array_: return v
    if type == 'S' and v is Array_ and (v as Array_).size > 0 and v[0] is string: return v
  return random-argument rng pool

/// A description of a value that does not depend on addresses.
describe value/any --depth/int=0 -> string:
  if depth > 2: return "..."
  if value is string:
    s := value as string
    if s.size <= 40: return "s\"$s\""
    return "s$(s.size):$(s.hash-code):$(List 20: s.at --raw it):$(List 20: s.at --raw s.size - 20 + it)"
  if value is ByteArray:
    b := value as ByteArray
    if b.size <= 40: return "b$b"
    return "b$(b.size):$(b.hash-code):$(b[0..16]):$(b[b.size - 16..])"
  if value is int: return "i$value"
  if value is float: return "f$((value as float).bits)"
  if value == null or value is bool: return "$value"
  if value is List:
    l := value as List
    return "L$(l.size)[$((l.size > 8 ? l[0..8] : l).map: describe it --depth=depth + 1)]"
  if value is Array_:
    a := value as Array_
    n := a.size > 8 ? 8 : a.size
    return "A$(a.size)[$((List n: a[it]).map: describe it --depth=depth + 1)]"
  return "o$(object-class-id value)"

object-class-id o -> int:
  #primitive.core.object-class-id

main args:
  seed := args.size > 0 ? int.parse args[0] : 1
  iterations := args.size > 1 ? int.parse args[1] : 100_000
  trace-from := args.size > 2 ? int.parse args[2] : -1
  trace-to := args.size > 3 ? int.parse args[3] : int.MAX
  ported := []
  PRIMITIVE-COUNT.repeat: if PORTED.contains PRIMITIVE-NAMES[it]: ported.add it
  if ported.size != PORTED.size: throw "primitives.toit lacks some ported primitives"
  rng := Rng seed
  pool := make-pool rng
  checksum := 0xcbf2_9ce4_8422_2325
  iterations.repeat: | iteration |
    if iteration % 1000 == 0:
      pool = make-pool rng
    index := ported[rng.next ported.size]
    name := PRIMITIVE-NAMES[index]
    arity := PRIMITIVE-ARITIES[index]
    signature := SIGNATURES.get name
    typed := signature != null and signature.size == arity and (rng.next 2) == 0
    arguments := List arity: typed
        ? typed-argument rng pool (signature.at --raw it)
        : random-argument rng pool
    if name == "core.array_new" or name == "core.byte_array_new":
      arguments.map --in-place: | arg | (arg is int and arg > MAX-SIZE) ? arg % MAX-SIZE : arg
    result := null
    exception := catch:
      result = call-primitive index arguments
    line := "$name $(exception ? "!$(describe exception)" : describe result) $(arguments.map: describe it)"
    if 0 <= trace-from <= iteration < trace-to:
      print "$iteration: $line"
    line.size.repeat:
      checksum = (checksum ^ (line.at --raw it)) * 0x100_0000_01b3
    if (iteration + 1) % 10_000 == 0:
      print "checksum $(iteration + 1) $checksum"
    if result != null and (rng.next 4) == 0:
      pool[rng.next pool.size] = result
  print "done $iterations $checksum"

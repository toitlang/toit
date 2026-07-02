// Tests basic Toit functionality on EC618.
// - Integer formatting (newlib int64 compatibility)
// - String operations
// - Collections

main:
  test-integer-formatting
  test-string-operations
  test-collections
  print "ALL TESTS PASSED"

test-integer-formatting:
  // 32-bit values.
  n := 12345
  assert-equals "12345" "$n"
  assert-equals "-12345" "$(-n)"
  zero := 0
  assert-equals "0" "$zero"

  // 64-bit values (exercises the manual int64_to_string path).
  big := 12345678901234
  assert-equals "12345678901234" "$big"
  assert-equals "-12345678901234" "$(-big)"

  // Hex and binary formatting.
  val := 255
  assert-equals "ff" "$(%x val)"
  assert-equals "FF" "$(%X val)"
  assert-equals "11111111" "$(%b val)"
  assert-equals "377" "$(%o val)"

  // Large hex.
  assert-equals "b3a73ce2ff2" "$(%x big)"

  print "  integer formatting: OK"

test-string-operations:
  s := "Hello, EC618!"
  assert-equals 13 s.size
  assert-equals "HELLO, EC618!" s.to-ascii-upper
  assert-equals "Hello" s[..5]
  assert-equals "EC618!" s[7..]
  assert: s.contains "EC618"
  assert: not s.contains "ESP32"

  print "  string operations: OK"

test-collections:
  // List.
  list := [1, 2, 3, 4, 5]
  assert-equals 15 (list.reduce: | a b | a + b)
  assert-equals [2, 4] (list.filter: it % 2 == 0)

  // Map.
  map := {"a": 1, "b": 2, "c": 3}
  assert-equals 3 map.size
  assert-equals 2 map["b"]
  map["d"] = 4
  assert-equals 4 map.size

  // Set.
  set := {1, 2, 3, 2, 1}
  assert-equals 3 set.size

  // ByteArray.
  ba := #[0x48, 0x65, 0x6c, 0x6c, 0x6f]
  assert-equals "Hello" ba.to-string

  print "  collections: OK"

assert-equals expected actual:
  if expected != actual:
    throw "Expected $expected, got $actual"

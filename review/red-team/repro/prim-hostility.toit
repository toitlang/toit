// Red-team: exercise allowed primitives from an untrusted container with
// hostile arguments (huge sizes, empty/edge slices, aliasing, hash-index
// churn, string/byte-array boundary ops). Run under ASan+UBSan:
// toit.run --untrusted prim-hostility.toit
// Expectation: Toit exceptions or OOM, never a memory error.

try-call lambda:
  catch: lambda.call

main:
  // byte array extremes
  try-call:: ByteArray 0
  try-call:: ByteArray 0x3fff_ffff
  try-call:: (ByteArray 10)[5..5]
  try-call:: (ByteArray 10)[10..10]
  try-call:: (ByteArray 10)[3..2]
  // string slices and boundary writes
  s := "hello world" * 10
  try-call:: s[0..0]
  try-call:: s[1..5].to-byte-array
  ba := ByteArray 32
  try-call:: s.write-to-byte-array ba 0 5 0
  try-call:: s.write-to-byte-array ba 0 s.size 0
  try-call:: s.write-to-byte-array ba 0 5 30
  // aliasing a byte array into itself via replace
  big := ByteArray 100 --initial=9
  try-call:: big.replace 0 big 10 90
  try-call:: big.replace 50 big 0 60
  // map/hash churn (rebuild_hash_index)
  m := {:}
  1000.repeat: m[it] = it
  500.repeat: m.remove it
  try-call:: m.remove 999999
  // list and array growth
  l := []
  10000.repeat: l.add it
  // string building
  acc := ""
  200.repeat: acc += "x"
  // integer parsing boundaries
  try-call:: int.parse "999999999999999999999999999999"
  try-call:: int.parse ""
  try-call:: float.parse "nan"
  // endian ops on slices
  bo := ByteArray 16
  try-call:: (bo)[2..10]
  print "prim-hostility done"

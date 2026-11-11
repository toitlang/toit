// Copyright (C) 2026 Toit contributors.
// Victim program: routes literal objects straight through the untrusted C++
// primitives and the object encoder (print / process_send / throw), so that a
// corrupted literal is consumed by trusted C++.
STR ::= "ABCDEFGHIJKLMNOP"      // string literal, consumed by slice/at/encoder
BA  ::= #[1,2,3,4,5,6,7,8]      // byte-array literal
D   ::= 2.5                      // float literal
BIG ::= 999999999999999999       // large-integer literal

main:
  // string primitives on a (possibly corrupted) literal backing
  print STR
  print STR[3..9]                // string_slice
  print STR[0]                   // string_at / raw_at
  print STR.size                 // string_length
  // byte-array primitives
  print BA
  print BA[2]                    // byte_array_at
  print BA.size                  // byte_array_length
  s := BA[1..5]                  // byte-array slice / cow
  print s
  // float / large int through encoders and arithmetic
  print D
  print (D + 1.0)
  print BIG
  print (BIG + 1)
  // object encoder via process_send to self (system)
  catch: process-send_ 0 [STR, BA, D, BIG] false
  print "done"

process-send_ pid/int message/any keep/bool -> none:
  #primitive.core.process_send

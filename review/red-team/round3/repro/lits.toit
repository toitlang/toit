// Copyright (C) 2026 Toit contributors.
// Literal-rich base program for the round-3 heap editor.
main:
  s := "hello-literal"
  ba := #[1, 2, 3, 4, 5]
  arr := [10, 20, 30]
  lst := [100, 200, 300, 400]        // List instance -> backing array literal
  m := {"k1": 1, "k2": 2}            // Map literal
  d := 3.5                           // double literal
  big := 123456789012345678          // large integer literal
  sl := "0123456789abcdef"[2..10]    // string slice at runtime
  print s
  print ba
  print arr
  print lst
  print m
  print d
  print big
  print sl

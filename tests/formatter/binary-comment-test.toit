main:
  // Binary with end-of-line comment should NOT be flattened.
  x := 1 + // comment
    2
  // Binary without comment should still be flattened.
  y := 3 +
    4

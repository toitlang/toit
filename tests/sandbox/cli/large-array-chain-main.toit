// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Compiled against a copy of the core library whose `LargeArray_` fields
// are assignable (run-patched-lib.cmake): a program's own library is part
// of its image, so an untrusted program can make any heap graph of its
// classes. This one makes a list whose backing is a chain of large arrays,
// each the vector of the next, of decreasing sizes. `list_add` on it used
// to reach the C++ `Interpreter::fast_at`, which recursed once per large
// array of the chain and overflowed the native stack: the VM crashed. The
// Rust port of list_add follows at most a few nested vectors and fails
// with INVALID_ARGUMENT; the Toit code of List.add then recurses on the
// program's own stack and ends in the program's STACK_OVERFLOW.

main args:
  n := int.parse args[0]
  // An arraylet whose first element is itself: element 0 of every large
  // array of the chain is this arraylet.
  a := Array_ 500 null
  a[0] = a
  prev/any := LargeArray_ 501 a
  for i := 1; i <= n; i++:
    node/any := LargeArray_ 501
    node.vector_ = prev
    node.size_ = 501 + i
    prev = node
  list/any := []
  list.array_ = prev
  list.size_ = 0
  print "chain of $n built"
  error := catch: list.add 42
  print "add: $error"
  // A chain of two still takes the primitive's path.
  short/any := LargeArray_ 501
  short.vector_ = LargeArray_ 501 a
  short.size_ = 502
  list2/any := []
  list2.array_ = short
  list2.size_ = 0
  list2.add 7
  print "short chain: size=$list2.size first=$(a[0])"
  print "survived"

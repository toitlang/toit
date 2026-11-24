// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

// The C++ concat-strings primitive summed the lengths of the parts in a
// word. On 32-bit, 257 references to a 16 MB string sum to 2^32 + 16 MB:
// the sum wrapped to 16 MB, a string of that size was allocated, and the
// copy of all parts wrote 4 GB past it (a segfault, or a corrupted heap).
// Reachable by untrusted programs: the verified core's port declines sums
// above MAX_BLOB_LENGTH (2^30 on 32-bit) and leaves them to the C++. Found
// auditing the C++ fallbacks of the Rust primitives (verified/cxx/annotated,
// wave 7). string-add had the same unchecked sum.

concat-strings_ array: #primitive.core.concat-strings
string-add_ a b: #primitive.core.string-add

main:
  // A small concatenation still works.
  expect-equals "ababab" (concat-strings_ (Array_ 3 "ab"))
  expect-equals "abc" (string-add_ "ab" "c")
  if system.BITS-PER-WORD != 32:
    print "64-bit: the sums cannot wrap; nothing else to test"
    return
  s := "x" * (16 * 1024 * 1024)
  array := Array_ 257 s
  expect-throw "OUT_OF_RANGE": concat-strings_ array
  // Just above the longest concatenation (2^30 - 1 bytes, a smi).
  array = Array_ 65 s
  expect-throw "OUT_OF_RANGE": concat-strings_ array
  // Exactly 2^30 bytes: one byte above the longest (wave 10; the bound
  // was 2^30 itself, which made a string longer than the heap model's
  // largest blob, its length not a smi).
  array = Array_ 64 s
  expect-throw "OUT_OF_RANGE": concat-strings_ array
  print "done"

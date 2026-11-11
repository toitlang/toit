// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes

// Run with 'toit run --untrusted'. Large byte arrays work as in trusted
// containers (their backing store is external, charged to the heap); only
// the explicit external and off-heap constructors are denied.
main:
  [100, 10_000, 1_000_000].do: | n/int |
    b := ByteArray n
    zero := true
    b.do: if it != 0: zero = false
    b[n - 1] = 42
    filled := ByteArray n --initial=7
    print "$n: size=$b.size zero=$zero last=$(b[n - 1]) filled=$(filled[n - 1])"
  buffer := bytes.Buffer.with-initial-size 1000  // @no-warn
  buffer.write "hello"
  print "buffer: $buffer.bytes.to-string"
  print "external: $(catch: ByteArray.external 1000)"
  print "off-heap: $(catch: create-off-heap-byte-array 1000)"

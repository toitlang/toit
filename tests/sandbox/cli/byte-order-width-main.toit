// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. ByteOrder.put-uint with 9 bytes writes the
// same bytes in either byte order and on either path of an untrusted
// process: the Rust port (a fresh byte array) and the C++ primitive (a
// byte-array literal, a copy-on-write byte array the port leaves to the C++).
// Until wave 10 put_uint_big_endian and its port accepted width 9 and wrote
// the arithmetic shift's sign byte (255 for a negative value) as the ninth
// byte, where little endian (and both fallbacks, lib/io/byte-order.toit)
// write 0 (verified/cxx/annotated/README.md, "Findings", wave 10).

import io show BIG-ENDIAN LITTLE-ENDIAN

as-list bytes/ByteArray -> List:
  return List bytes.size: bytes[it]

main:
  fresh-big := ByteArray 9
  BIG-ENDIAN.put-uint fresh-big 9 0 -1
  literal-big := #[1, 1, 1, 1, 1, 1, 1, 1, 1]
  BIG-ENDIAN.put-uint literal-big 9 0 -1
  fresh-little := ByteArray 9
  LITTLE-ENDIAN.put-uint fresh-little 9 0 -1
  literal-little := #[1, 1, 1, 1, 1, 1, 1, 1, 1]
  LITTLE-ENDIAN.put-uint literal-little 9 0 -1
  print "big: $(as-list fresh-big) $(as-list literal-big)"
  print "little: $(as-list fresh-little) $(as-list literal-little)"
  // Widths up to 8 are unchanged.
  eight := #[0, 0, 0, 0, 0, 0, 0, 0]
  BIG-ENDIAN.put-uint eight 8 0 0x0102030405060708
  print "eight: $(as-list eight)"

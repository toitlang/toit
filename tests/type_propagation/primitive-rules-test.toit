// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-returns-argument
  test-decoded
  test-always-fails

test-returns-argument:
  id (at-put_ (Array_ 1) 0 "foo")
  id (at-put_ (Array_ 1) 0 1.5)
  id (write-to_ "foo" (ByteArray 3) 0 3 0)

test-decoded:
  id (tison-decode_ #[0])

test-always-fails:
  // The primitive never returns normally, so the code after it is dead.
  catch:
    opendir_ "foo"
    id 42

id x:
  return x

at-put_ array index value:
  #primitive.core.array-at-put

write-to_ source dest from to dest-index:
  #primitive.core.string-write-to-byte-array

tison-decode_ bytes:
  #primitive.encoding.tison-decode

opendir_ name:
  #primitive.file.opendir

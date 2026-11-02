// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *
import host.directory
import host.file
import system

// The build that checks propagated types verifies the value returned from each
// primitive against the type rule for that primitive, so this test runs the
// primitives that have rules that depend on their arguments, or that aren't
// otherwise reached by our tests.

main:
  test-readlink
  test-returns-argument
  test-decoded

test-readlink:
  if system.platform == system.PLATFORM-WINDOWS: return
  dir := directory.mkdtemp "/tmp/primitive-results-test-"
  try:
    path := "$dir/link"
    file.link --file --source=path --target="target"
    expect-equals "target" (file.readlink path)
  finally:
    directory.rmdir --recursive dir

test-returns-argument:
  array := Array_ 1
  expect-equals "foo" (at-put_ array 0 "foo")
  expect-equals 1.5 (at-put_ array 0 1.5)
  expect-null (at-put_ array 0 null)

  bytes := ByteArray 3
  expect-identical bytes (write-to_ "foo" bytes 0 3 0)
  expect-equals #['f', 'o', 'o'] bytes

test-decoded:
  [ 42, -42, 0x1_0000_0000_0000, 1.5, true, false, null, "foo", #[1, 2], [1, 2], {"foo": 1} ].do:
    expect-structural-equals it (tison.decode (tison.encode it))

at-put_ array index value:
  #primitive.core.array-at-put

write-to_ source dest from to dest-index:
  #primitive.core.string-write-to-byte-array

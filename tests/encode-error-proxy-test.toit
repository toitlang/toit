// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// encode_error (the exception and trace encoder) must not read a proxy
// byte array (an external byte array whose address is a C++ struct: a
// timer, a resource group) as bytes. It called ByteArray::Bytes on it,
// whose as_external asserts a raw tag: assertion-enabled builds stopped the
// VM (found by the core fuzzer on the sanitizer build); release builds read
// the proxy's length, 0. Now a proxy is encoded as an empty byte array.

import expect show *

main:
  timer := timer-create_ timer-resource-group_
  // As the message of an error, and inside a list.
  [timer, [timer], [[1, timer]]].do: | message |
    encoded := encode-error_ "X" message
    expect encoded is ByteArray
  // The raw byte arrays around it are still encoded.
  plain := encode-error_ "X" #[1, 2, 3]
  expect plain is ByteArray

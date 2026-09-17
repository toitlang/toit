// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import tls.session as session

main:
  test-set-incoming

/**
Sets incoming data with and without an offset.

The socket frees the previous packet when a new one is set, and when it is
  closed, so a wrong pointer is caught by the allocator.
*/
test-set-incoming:
  group := session.tls-init_ false
  socket := session.tls-create_ group "localhost"

  // External byte arrays are taken over, not copied.
  external := ByteArray.external 10
  session.tls-set-incoming_ socket external 0
  expect-equals 0 external.size

  external = ByteArray.external 10
  session.tls-set-incoming_ socket external 3
  expect-equals 0 external.size

  // Other byte arrays are copied.
  internal := ByteArray 10
  session.tls-set-incoming_ socket internal 3
  expect-equals 10 internal.size

  session.tls-set-incoming_ socket (ByteArray 10) 0
  session.tls-close_ socket
  session.tls-deinit_ group

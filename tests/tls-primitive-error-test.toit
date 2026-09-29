// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import tls.session as tls

main:
  test-error --read
  test-error --no-read

test-error --read/bool:
  group := tls.tls-init_ false
  socket := tls.tls-create_ group "localhost"
  try:
    tls.tls-init-socket_ socket "" true
    // TLS I/O also advances an unfinished handshake. Supply a malformed
    // record so that the native call fails after consuming input.
    tls.tls-set-incoming_ socket #[22, 4, 0, 0, 1, 0] 0
    status := read
        ? tls.tls-read_ socket
        : tls.tls-write_ socket #[42] 0 1
    expect (status is int and status < 0)
    // Error reporting is a separate operation. It must retain the same result
    // when retried, without entering Mbed TLS again.
    error := catch: tls.tls-error_ socket -status
    expect (error is string)
    expect-equals error (catch: tls.tls-error_ socket -status)
  finally:
    tls.tls-close_ socket
    tls.tls-deinit_ group

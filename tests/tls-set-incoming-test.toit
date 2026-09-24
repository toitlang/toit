// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import tls.session as session

main:
  test-set-incoming
  test-handshake-message-is-taken

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

  // External byte arrays the process doesn't own are copied.
  rtc := rtc-user-bytes_
  size := rtc.size
  session.tls-set-incoming_ socket rtc 0
  expect-equals size rtc.size

  session.tls-set-incoming_ socket (ByteArray 10) 0
  session.tls-close_ socket
  session.tls-deinit_ group

/**
The synthetic handshake records built from the wire data are external, so the
  VM can take them without making a copy.
*/
test-handshake-message-is-taken:
  // A handshake record containing one 16-byte ServerHello message.
  message-size := 16
  record := #[22, 3, 3, 0, 4 + message-size, 2, 0, 0, message-size] + (ByteArray message-size)
  tls-session := session.Session.client (TestReader record) io.Buffer

  synthetic := tls-session.extract-first-message_
  expect-equals 5 + 4 + message-size synthetic.size

  group := session.tls-init_ false
  socket := session.tls-create_ group "localhost"
  session.tls-set-incoming_ socket synthetic 0
  expect-equals 0 synthetic.size
  session.tls-close_ socket
  session.tls-deinit_ group

// There is no closeable reader over a byte array in lib/io.
class TestReader extends io.CloseableReader:
  data_/ByteArray? := ?

  constructor .data_:

  read_ -> ByteArray?:
    result := data_
    data_ = null
    return result

  close_ -> none:

rtc-user-bytes_ -> ByteArray:
  #primitive.core.rtc-user-bytes

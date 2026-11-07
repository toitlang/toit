// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io
import uart

/** Adapts an externally owned UART to the closeable streams required by TLS. */
class Reader extends io.CloseableReader:
  port_/uart.Port
  constructor .port_:
  read_ -> ByteArray?:
    return port_.in.read
  close_ -> none:

class Writer extends io.CloseableWriter:
  port_/uart.Port
  constructor .port_:
  try-write_ data/io.Data from/int to/int -> int:
    return port_.try-write_ data from to
  close_ -> none:

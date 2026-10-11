// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

/** A sample of the native receive queue, with storage owned by this sample. */
class QueueDiagnostics:
  bytes_/ByteArray

  constructor .bytes_:

  /** Returns the queue capacity in packets. */
  capacity -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 0
  /** Returns the sampled number of queued packets. */
  queued -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 4
  /** Returns a conservative peak packet count since open. */
  high-water -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 8
  /** Returns the advertising-report drop count, modulo 2^32. */
  scan-drops -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 12
  /** Returns null, or the terminal native queue fault. */
  fault -> string?:
    code := io.LITTLE-ENDIAN.uint32 bytes_ 16
    if code == 0: return null
    if code == 1: return "HCI_INVALID_PACKET"
    if code == 2: return "HCI_OVERSIZED_PACKET"
    if code == 3: return "HCI_QUEUE_OVERFLOW"
    return "HCI_UNKNOWN_QUEUE_FAULT"

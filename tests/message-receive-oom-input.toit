// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The program of message-receive-oom-test-compiler.toit: a receiver that
// runs out of memory while decoding a message, and then dies.
//
// The message is a byte array of 200 bytes (above the inline size: the
// sender's encoder copies it into a malloced block) followed by lists the
// receiver's heap can not hold. The receiver's decoder gives the block to
// a new external byte array, fails on a list, gives the block back to the
// message (the byte array's finalizer bit is cleared) and fails again on
// the retry after the GC: task_receive_message throws, uncaught, and the
// program ends (no GC in between).

TYPE ::= 4711  // Any type a process may send; the receiver has no handler.

main:
  receiver := spawn::
    set-max-heap-size_ 4 * 32768
    sleep --ms=5_000

  // Let the receiver install its heap limit.
  sleep --ms=200
  lists := List 128: List 400 0
  process-send_ receiver.id TYPE [ByteArray 200 --initial=7] + lists
  sleep --ms=2_000

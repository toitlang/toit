// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import expect show *
import rp2040.pio
import system

// PIO loopback entirely inside a state machine. No external pins are driven.
main:
  program := pio.Program [0x80a0, 0xa0c7, 0x8020]  // PULL; MOV ISR, OSR; PUSH.
  machine := pio.StateMachine program
  try:
    machine.start
    with-timeout --ms=10_000:
      // More than one FIFO's worth exercises DMA and task wakeups. Collect
      // while transfers own the native buffers, testing the movable-heap case.
      [true, false].do: |copy/bool|
        words := ByteArray.external 256
        words.size.repeat: words[it] = it
        expected := words.copy
        destination := ByteArray.external words.size
        tx := machine.submit-write words --copy=copy
        try:
          rx := machine.submit-read destination --copy=copy
          try:
            system.process-stats --gc
            tx.wait
            rx.wait
            expect-equals expected tx.take-buffer
            expect-equals expected rx.take-buffer
            if not copy:
              expect-equals 0 words.size
              expect-equals 0 destination.size
          finally:
            rx.close
        finally:
          tx.close
  finally:
    machine.close
  print "RP2040 PIO smoke: PASS"

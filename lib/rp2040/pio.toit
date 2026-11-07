// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Programmable I/O on RP2040.

Uses the same program, state-machine and asynchronous transfer API as RP2350.
  RP2040 accepts PIO version 0 programs and has two PIO blocks. Extended FIFO
  modes and IRQ MOV-status selection are unavailable. Input pin lists reserve
  the pins, but the hardware does not mask other pins when reading MOV PINS;
  IN PINS reads the number of bits specified by the instruction.
*/
import rp2350.pio show *
export *

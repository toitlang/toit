// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Different formats with different data-sizes.
// Board1 is the reader and master.
// ARG: philips16 msb16 pcm16 philips32 msb32 pcm32 philips24 pcm8
// Board1 is the reader and slave.
// ARG: philips16-slave philips24-slave msb8-slave
// Board1 is the writer and master.
// ARG: philips16-writer
// Board1 is the writer and slave.
// ARG: philips16-writer-slave
// Board1 is the reader, master, and emits a master clock signal.
// ARG: pcm32-mclk msb16-mclk
// Board1 is the writer, slave, and emits a master clock signal.
// ARG: philips16-slave-writer,mclk msb32-slave-writer-mclk
// Stress-tests. We use 'slave', so that board2 can initiate the transfer and
//   we don't lose too much data.
// ARG: philips16-fast-slave msb16-writer-fast-slave
// ARG: pcm16-outstereoleft pcm16-outstereoright pcm16-outmonoboth pcm16-outmonoleft pcm16-outmonoright
// ARG: pcm16-inmonoleft pcm16-inmonoright
// ARG: pcm32-outstereoleft pcm32-inmonoleft

import .i2s-shared as shared

main args:
  shared.board1 args

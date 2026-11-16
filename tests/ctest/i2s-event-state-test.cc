// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

#include <stdio.h>
#include <stdlib.h>

#include "../../src/resources/i2s_event_state.h"

using toit::I2sEventState;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

int main() {
  // Duplex DMA can complete both directions before the event queue drains.
  // Neither waiter may be stranded when notifications share a queue entry.
  CHECK(I2sEventState::merge(0, I2sEventState::READ | I2sEventState::WRITE) == 3);
  for (unsigned existing = 0; existing < 8; existing++) {
    for (unsigned pending = 0; pending < 8; pending++) {
      unsigned result = I2sEventState::merge(existing, pending);
      CHECK((result & 1) == ((existing & 1) || (pending & 1) ? 1 : 0));
      CHECK((result & 2) == ((existing & 2) || (pending & 2) ? 2 : 0));
      CHECK((result & 4) == ((existing & 4) || (pending & 4) ? 4 : 0));
      CHECK(I2sEventState::merge(result, pending) == result);
    }
  }
  // Preserve existing state but never introduce unrelated incoming bits.
  CHECK(I2sEventState::merge(0x80, 0x40 | 3) == 0x83);
  puts("I2S coalesced read/write/error notifications PASS");
}

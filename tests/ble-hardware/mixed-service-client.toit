// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system

SIGNAL ::= 1000
WAIT ::= 1001

// Coordination belongs only to this hardware fixture's provider.
class Client extends service.Client:
  signal event/int -> none: invoke_ SIGNAL event
  wait event/int -> none: invoke_ WAIT event

check-values [read]:
  before := system.process-stats
  retained/ByteArray? := null
  100.repeat: | index/int |
    value/ByteArray := read.call
    if value != "Toit HCI".to-byte-array: throw "MIXED_VALUE_MISMATCH"
    if index == 0: retained = value
    if index % 10 == 0: system.process-stats --gc
  if retained != "Toit HCI".to-byte-array: throw "MIXED_RETAINED_VALUE_CHANGED"
  after := system.process-stats
  if after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT] < 10:
    throw "MIXED_GC_COUNT"

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as shared

PRESSURE ::= 1000

main:
  with-timeout --ms=10_000:
    spawn:: provider-main
    first := PressureClient
    second := clients.Client
    first.open --timeout=(Duration --s=1)
    second.open
    readers := []
    results := [monitor.Latch, monitor.Latch]
    try:
      a := first.connect (links.address 1) --address-type=1
      b := second.connect (links.address 2) --address-type=1
      readers.add (task:: results[0].set (a.read 3))
      readers.add (task:: results[1].set (b.read 3))
      report := first.pressure
      expect (["ALLOCATION_FAILED", "OUT_OF_MEMORY"].contains report[0])
      expect (report[1] > 0)
      expect (report[3] > report[2])
      expect-equals #[42] results[0].get
      expect-equals #[43] results[1].get
      expect-equals #[44] (a.read 3)
      expect-equals #[45] (b.read 3)
      a.disconnect
      b.disconnect
      print "BLE_HEAP_PRESSURE limit=262144 allocations=$(report[1]) failure=$(report[0]) compacting-before=$(report[2]) compacting-after=$(report[3]) recovered=2 fresh-reads=2"
    finally:
      readers.do: it.cancel
      first.close
      second.close

provider-main:
  provider := Provider
  provider.install
  task::
    radio := provider.radio
    fixture.initialize-replies radio
    links.establish radio 1 0x234
    links.establish radio 2 0x235
    seen := {}
    2.repeat:
      packet := radio.sent.take
      expect-equals #[0x0a, 3, 0] packet[9..]
      handle := packet[1] | packet[2] << 8
      expect (handle == 0x234 or handle == 0x235)
      expect (not (seen.contains handle))
      seen.add handle
      links.completed radio handle
    provider.pending.set true
    provider.released.get
    shared.incoming radio 0x234 #[0x0b, 42]
    shared.incoming radio 0x235 #[0x0b, 43]
    shared.sent radio 0x234 #[0x0a, 3, 0]
    shared.incoming radio 0x234 #[0x0b, 44]
    shared.sent radio 0x235 #[0x0a, 3, 0]
    shared.incoming radio 0x235 #[0x0b, 45]
    shared.disconnect radio 0x234
    shared.disconnect radio 0x235
  provider.uninstall --wait

class PressureClient extends clients.Client:
  constructor: super
  pressure -> List: return invoke_ PRESSURE null

class Provider extends shared.Provider:
  pending/monitor.Latch ::= monitor.Latch
  released/monitor.Latch ::= monitor.Latch

  constructor: super

  handle index/int arguments/any --gid/int --client/int -> any:
    if index != PRESSURE: return super index arguments --gid=gid --client=client
    pending.get
    // Only this spawned provider process is constrained. The parent and other
    // running VMs retain their own heap limits.
    before := (system.process-stats --gc)[10]
    set-max-heap-size_ (256 * 1024)
    ballast := []
    allocated := 0
    failure := catch:
      while true:
        // Small values stay managed; keep every allocation live until failure.
        ballast.add (ByteArray 128 --initial=42)
        allocated++
    ballast.clear
    after := (system.process-stats --gc)[10]
    expect (["ALLOCATION_FAILED", "OUT_OF_MEMORY"].contains failure)
    released.set true
    return [failure, allocated, before, after]

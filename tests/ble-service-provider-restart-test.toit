// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.service.client as clients
import .ble-fixture as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as shared

CRASH ::= 1000

main: run

run --oom/bool=false --external-provider/bool=false:
  with-timeout --ms=10_000:
    if not external-provider: spawn:: provider-main true --oom=oom
    first := CrashClient
    second := clients.Client
    first.open --timeout=(Duration --s=1)
    second.open
    a := first.connect (links.address 1) --address-type=1
    b := second.connect (links.address 2) --address-type=1
    results := [monitor.Latch, monitor.Latch]
    readers := []
    try:
      readers.add (task:: results[0].set (catch: a.read 3))
      readers.add (task:: results[1].set (catch: b.read 3))
      crash-error := catch: first.crash
      expect-equals "NO_SUCH_PROCESS" crash-error
      results.do: expect-equals "NO_SUCH_PROCESS" it.get
      spawn:: provider-main false
      fresh := clients.Client
      fresh.open --timeout=(Duration --s=1)
      try:
        fresh.with-connection (links.address 1) --address-type=1: | current |
          expect-throw "NO_SUCH_PROCESS": a.read 3
          expect-throw "NO_SUCH_PROCESS": a.disconnect
          expect-throw "NO_SUCH_PROCESS": b.disconnect
          a.disconnect
          b.disconnect
          expect-equals #[43] (current.read 3)
      finally:
        fresh.close
    finally:
      readers.do: it.cancel
      first.close
      second.close
    print "BLE_PROVIDER_RESTART COMPLETE oom=$oom waiters=2 stale-handles=invalid replacement-read=43"

provider-main crash/bool --oom/bool=false:
  provider := Provider --oom=oom
  provider.install
  task::
    radio := provider.radio
    fixture.initialize-replies radio
    links.establish radio 1 0x234
    if crash:
      links.establish radio 2 0x235
      // The two RPC calls can reach the controller in either order.
      seen := {}
      2.repeat:
        packet := radio.sent.take
        expect-equals #[0x0a, 3, 0] packet[9..]
        expect (packet[1] == 0x34 or packet[1] == 0x35)
        expect (not (seen.contains packet[1]))
        seen.add packet[1]
        links.completed radio (packet[1] | packet[2] << 8)
      provider.pending.set true
    else:
      shared.sent radio 0x234 #[0x0a, 3, 0]
      shared.incoming radio 0x234 #[0x0b, 43]
      shared.disconnect radio 0x234
  provider.uninstall --wait

class CrashClient extends clients.Client:
  constructor: super
  crash -> none: invoke_ CRASH null

class Provider extends shared.Provider:
  pending/monitor.Latch ::= monitor.Latch
  never/monitor.Latch ::= monitor.Latch
  oom_/bool
  constructor --oom/bool=false:
    oom_ = oom
    super
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CRASH:
      pending.get
      if oom_:
        // Fail in a background task so the RPC exception serializer cannot
        // turn the allocation failure into an ordinary method error.
        task::
          set-max-heap-size_ (256 * 1024)
          ballast := []
          while true: ballast.add (ByteArray 128 --initial=42)
        never.get
      // Terminate the provider process with two confirmed pending ATT reads.
      exit 0
    return super index arguments --gid=gid --client=client

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.transport
import expect show *
import system

PROBE-STORAGE ::= 1000

main:
  with-timeout --ms=5_000:
    spawn::
      provider := Provider
      provider.install
      provider.uninstall --wait
    client := ObservedClient
    client.open
    try:
      session := client.configure --value-limit=512 --mtu-limit=517
      uuid := ByteArray.external 2
      uuid.replace 0 #[0xf0, 0xff]
      session.add-service uuid
      expect-equals #[0xf0, 0xff] uuid
      uuid[0] = 0xf1
      initial := ByteArray.external 512
      initial.fill 42
      handle := session.add-characteristic uuid --read --write --value=initial
      expect-equals #[0xf1, 0xff] uuid
      expect-equals (ByteArray 512 --initial=42) initial
      uuid[0] = 0xf2
      session.add-descriptor handle uuid --value=initial
      expect-equals #[0xf2, 0xff] uuid
      expect-equals (ByteArray 512 --initial=42) initial
      oversized := ByteArray.external 4096
      oversized.fill 42
      calls := client.calls
      expect-throw "INVALID_ARGUMENT": session.set-value handle oversized
      expect-throw "INVALID_ARGUMENT": session.add-service oversized
      expect-throw "INVALID_ARGUMENT": session.add-characteristic uuid --value=oversized
      expect-throw "INVALID_ARGUMENT": session.add-descriptor handle uuid --value=oversized
      expect-throw "INVALID_ARGUMENT": session.start oversized
      expect-throw "INVALID_ARGUMENT": session.start #[] --scan-response=oversized
      expect-throw "INVALID_ARGUMENT": client.connect oversized
      expect-throw "INVALID_ARGUMENT": client.scan --service-uuid=oversized: unreachable
      expect-throw "INVALID_ARGUMENT": client.with-advertising oversized: unreachable
      expect-throw "INVALID_ARGUMENT": client.with-advertising #[] --scan-response=oversized: unreachable
      expect-equals calls client.calls
      expect-equals (ByteArray 4096 --initial=42) oversized
      [20, 128, 129, 512].do: | size/int |
        expected := ByteArray size: it % 251
        value := ByteArray.external size
        value.replace 0 expected
        session.set-value handle value
        expect-equals expected value
        retained := session.value handle
        expect-equals expected retained
        // RPC-returned large values must also survive being passed back.
        session.set-value handle retained
        system.process-stats --gc
        expect-equals expected retained
        expect-equals expected (session.value handle)
        // Raw RPC transfers external storage, but copies internal storage.
        // Observe actual backing behavior rather than assuming it from type.
        compact := retained.copy
        expect-equals size (client.probe-storage compact)
        expect-equals expected compact
        system.process-stats --gc
        expect-equals expected compact
        expect-equals size (client.probe-storage retained)
        if size > 128:
          expect retained.is-empty
        else:
          expect-equals expected retained
      session.close
    finally:
      client.close

class Provider extends providers.Provider:
  constructor: super
  open-transport -> transport.Transport: unreachable
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PROBE-STORAGE: return arguments[0].size
    return super index arguments --gid=gid --client=client

class ObservedClient extends clients.Client:
  calls/int := 0
  probe-storage value/ByteArray -> int: return invoke_ PROBE-STORAGE [value]
  invoke_ index/int arguments/any -> any:
    calls++
    return super index arguments

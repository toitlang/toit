// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A service-RPC retention experiment; it does not open a radio controller.
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.transport
import encoding.json
import expect show *
import system

SIZES ::= [20, 128, 129, 244, 512]

main args/List:
  if args.size != 1 or (args[0] != "raw" and args[0] != "copy"):
    throw "Usage: retained-values.toit <raw|copy>"
  run --copy-received=(args[0] == "copy")

run --copy-received/bool=false:
  with-timeout --ms=60_000:
    spawn::
      provider := Provider
      provider.install
      provider.uninstall --wait
    client := clients.Client
    client.open --timeout=(Duration --s=5)
    try:
      session := client.configure --value-limit=512 --mtu-limit=517
      session.add-service #[0xf0, 0xff]
      handle := session.add-characteristic #[0xf1, 0xff] --read --value=#[]
      retained := List 64
      began := Time.monotonic-us --since-wakeup
      measure "baseline" copy-received began 0
      64.repeat: | sequence/int |
        retained[sequence] = receive session handle sequence copy-received
      validate retained
      measure "filled" copy-received began 64
      // Replacing mixed-size entries releases earlier buffers at different times.
      4.repeat: | round/int |
        64.repeat: | slot/int |
          sequence := 64 + round * 64 + slot
          retained[slot] = receive session handle sequence copy-received
        validate retained
        measure "churn-$round" copy-received began 64
        validate retained
      32.repeat: retained[it * 2] = null
      measure "half-released" copy-received began 32
      validate retained
      retained.fill null
      measure "released" copy-received began 0
      session.close
      print "BLE_RETAINED_VALUES COMPLETE mode=$(copy-received ? "copy" : "raw") received=320 validated=true"
    finally:
      client.close

receive session/clients.Session handle/int sequence/int copy-received/bool -> List:
  expected := payload sequence
  session.set-value handle expected
  received := session.value handle
  expect-equals expected received
  if copy-received: received = received.copy
  return [sequence, received]

payload sequence/int -> ByteArray:
  return ByteArray SIZES[sequence % SIZES.size]: (sequence + it) % 251

validate retained/List:
  retained.do: | entry/List? |
    if entry: expect-equals (payload entry[0]) entry[1]

measure phase/string copy-received/bool began/int count/int:
  stats := system.process-stats --gc
  print "BLE_RETAINED_VALUES " + (json.encode {
    "phase": phase,
    "mode": copy-received ? "copy" : "raw",
    "retained": count,
    "elapsed_awake_us": (Time.monotonic-us --since-wakeup) - began,
    "process_stats": stats,
  }).to-string

class Provider extends providers.Provider:
  constructor: super
  open-transport -> transport.Transport: unreachable

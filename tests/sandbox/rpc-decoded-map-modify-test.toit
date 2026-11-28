// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A map that a sandbox receives over RPC can be modified like any other map.

The message decoder used to give a decoded map an array as backing, so
  adding a key threw COLLECTION_CANNOT_CHANGE_SIZE and a removal that
  compacted the backing failed. Now the backing is a list.

A trusted provider returns maps; the sandboxed client adds keys to them and
  removes keys until the backing compacts. The sandboxed client also sends
  a map to the provider, where the same is done to the arguments, and
  runs the same provider as a sandbox (granted to provide services).
*/

import expect show *
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient TAG-UNTRUSTED-PROVIDER

ROLE-KEY ::= "role"
COUNT ::= 20

interface MapService:
  static SELECTOR ::= ServiceSelector
      --uuid="5b9a0c7e-2d41-4c68-a3f5-7e8d9c0b1a24"
      --major=1
      --minor=0

  // Returns a map from 0 to $COUNT - 1 to the number as string.
  make -> Map
  static MAKE-INDEX ::= 0

  // Modifies the $map it received (adds a key, removes keys until the
  // backing compacts, adds again) and returns its keys.
  modify map/Map -> List
  static MODIFY-INDEX ::= 1

class MapClient extends ServiceClient implements MapService:
  constructor selector/ServiceSelector=MapService.SELECTOR:
    super selector

  make -> Map: return invoke_ MapService.MAKE-INDEX null
  modify map/Map -> List: return invoke_ MapService.MODIFY-INDEX map

class MapProvider extends ServiceProvider implements MapService ServiceHandler:
  constructor:
    super "test/map" --major=1 --minor=0
    provides MapService.SELECTOR --handler=this

  accepts-untrusted-clients -> bool:
    return true

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == MapService.MAKE-INDEX: return make
    if index == MapService.MODIFY-INDEX: return modify arguments
    unreachable

  make -> Map:
    result := {:}
    COUNT.repeat: result[it] = "$it"
    return result

  modify map/Map -> List:
    change map
    return map.keys

/** Adds and removes keys of a map that came out of the message decoder. */
change map/Map -> none:
  size := map.size
  map[1000] = "1000"
  expect-equals size + 1 map.size
  expect-equals "1000" map[1000]
  // Enough removals to compact the backing.
  15.repeat: map.remove it
  expect-equals size - 14 map.size
  map[1001] = "1001"
  map.update 1002 --init="" : it + "x"
  expect-equals "x" map[1002]
  expect-equals "1001" map[1001]
  expect-equals "19" map[19]
  map.filter --in-place: | key value | key != 19
  expect-equals [1000, 1001, 1002] (map.keys.copy (map.size - 3) map.size)
  expect-equals [15, 16, 17, 18, 1000, 1001, 1002] map.keys

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "provider":
      (MapProvider).install
      while true: sleep --ms=1_000
    else if role == "client":
      run-client
    else:
      throw "Unknown role: $role"
    return
  run-driver

check client/MapClient -> none:
  map := client.make
  expect-equals COUNT map.size
  change map
  keys := client.modify (client.make)
  expect-equals [15, 16, 17, 18, 1000, 1001, 1002] keys

// The sandboxed client of the provider.
run-client -> none:
  client := MapClient
  client.open --timeout=(Duration --s=5)
  check client
  client.close

run-driver:
  p-stopped := false
  p := containers.start containers.current {ROLE-KEY: "provider"}
      --on-stopped=:: p-stopped = true
  trusted := MapClient
  trusted.open --timeout=(Duration --s=5)
  check trusted

  sandboxed := containers.start containers.current {ROLE-KEY: "client"} --untrusted
      --services=[MapService.SELECTOR.uuid]
  expect-equals 0 sandboxed.wait
  expect-not p-stopped
  trusted.close
  p.stop

  // The provider in a sandbox receives maps in its arguments.
  y-stopped := false
  y := containers.start containers.current {ROLE-KEY: "provider"}
      --untrusted
      --may-provide-services
      --on-stopped=:: y-stopped = true
  y-client := MapClient (MapService.SELECTOR.restrict.allow --tag=TAG-UNTRUSTED-PROVIDER)
  y-client.open --timeout=(Duration --s=5)
  check y-client
  expect-not y-stopped
  y-client.close
  y.stop
  print "OK"

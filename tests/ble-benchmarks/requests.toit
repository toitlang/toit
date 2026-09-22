// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A software comparison, not a radio throughput or native-memory benchmark.
import encoding.json
import expect show *
import system

import ble.experimental.attribute-server as attributes
import ble.experimental.service.client as clients
import ble.experimental.service.provider as providers
import ble.experimental.service.requests as bridge

WARMUP ::= 100
BEGIN ::= 0xfffe
END ::= 0xffff

main args/List:
  if not 2 <= args.size <= 3: throw "Usage: requests.toit <direct|rpc|rpc-copy> <cycles> [value bytes]"
  count := int.parse args[1]
  value-size := args.size == 3 ? (int.parse args[2]) : 20
  if not 0 <= value-size <= 512: throw "INVALID_ARGUMENT"
  if not 1 <= count <= 100_000: throw "INVALID_ARGUMENT"
  with-timeout --ms=120_000:
    if args[0] == "direct":
      application := Application value-size
      drive WARMUP 0 value-size
          (: | request | application.read request)
          (: | request | application.validate request)
          (: | handle/int value/ByteArray | application.written handle value)
      result := drive count WARMUP value-size
          (: | request | application.read request)
          (: | request | application.validate request)
          (: | handle/int value/ByteArray | application.written handle value)
      result["mode"] = "direct"
      print (json.encode result).to-string
    else if args[0] == "rpc" or args[0] == "rpc-copy":
      provider := Provider count value-size
      provider.install
      try:
        copy-received := args[0] == "rpc-copy"
        spawn:: application-client value-size --copy-received=copy-received
        provider.uninstall --wait
      finally:
        provider.uninstall
    else:
      throw "INVALID_ARGUMENT"

payload sequence/int size/int -> ByteArray:
  value := ByteArray size --initial=0x5a
  (min 4 size).repeat: value[it] = (sequence >> (8 * it)) & 0xff
  return value

drive count/int offset/int value-size/int [read] [validate] [written] -> Map:
  database := attributes.Database --value-limit=(max 20 value-size) --mtu-limit=517
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --dynamic-read --validate-write
  session := database.session
  session.request #[2, 5, 2]
  session.response-sent
  samples := List count
  before := system.process-stats --gc
  began := Time.monotonic-us
  try:
    count.repeat: | index/int |
      started := Time.monotonic-us
      value := payload (offset + index) value-size
      expect-equals (#[0x0b] + value) (session.request #[0x0a, 3, 0] read validate)
      expect-equals #[0x13] (session.request (#[0x12, 3, 0] + value) read validate)
      session.writes-do written
      samples[index] = Time.monotonic-us - started
  finally:
    session.close
  elapsed := Time.monotonic-us - began
  after := system.process-stats
  live := system.process-stats --gc
  sorted := samples.sort
  result := allocation-result before after
  result["cycles"] = count
  result["value_bytes"] = value-size
  result["elapsed_us"] = elapsed
  result["median_cycle_us"] = sorted[count / 2]
  result["p95_cycle_us"] = sorted[min (count - 1) (count * 95 / 100)]
  result["allocated_after_gc"] = live[system.STATS-INDEX-ALLOCATED-MEMORY]
  result["sample_slots"] = count
  return result

allocation-result before/List after/List -> Map:
  return {
    "cumulative_allocated_bytes": after[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP] -
        before[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP],
    "allocated_before": before[system.STATS-INDEX-ALLOCATED-MEMORY],
    "allocated_end_before_gc": after[system.STATS-INDEX-ALLOCATED-MEMORY],
    "full_gcs": after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT],
  }

// The same application checks run through direct blocks and the RPC facade.
class Application:
  value-size/int
  copy-received/bool
  constructor .value-size --.copy-received=false:

  sequence/int := 0
  baseline/List? := null

  read request -> none:
    if request.handle == BEGIN:
      baseline = system.process-stats --gc
      request.reply #[]
    else if request.handle == END:
      after := system.process-stats
      result := allocation-result baseline after
      live := system.process-stats --gc
      result["allocated_after_gc"] = live[system.STATS-INDEX-ALLOCATED-MEMORY]
      result["value_bytes"] = value-size
      result["mode"] = copy-received ? "rpc-client-copy" : "rpc-client"
      result["cycles"] = sequence - WARMUP
      print (json.encode result).to-string
      request.reply #[]
    else:
      expect-equals 3 request.handle
      request.reply (payload sequence value-size)

  validate request -> none:
    expect-equals 3 request.handle
    value := copy-received ? request.value.copy : request.value
    expect-equals (payload sequence value-size) value
    request.accept

  written handle/int value/ByteArray -> none:
    if copy-received: value = value.copy
    expect-equals 3 handle
    expect-equals (payload sequence value-size) value
    sequence++

application-client value-size/int --copy-received/bool=false:
  client := clients.Client
  client.open --timeout=(Duration --s=5)
  try:
    session := client.session
    application := Application value-size --copy-received=copy-received
    session.serve
        (: | request | application.read request)
        (: | request | application.validate request)
        (: | handle/int value/ByteArray | application.written handle value)
  finally:
    client.close

class Provider extends providers.Provider:
  count/int
  value-size/int

  constructor .count .value-size:
    super

  create-session client/int -> providers.Session:
    return Session this client count value-size

class Session extends providers.Session:
  worker_/Task? := null

  constructor provider/Provider client/int count/int value-size/int:
    super provider client --value-limit=(max 20 value-size)
    worker_ = task::
      try:
        drive WARMUP 0 value-size
            (: | request | requests.read request)
            (: | request | requests.validate request)
            (: | handle/int value/ByteArray | requests.written handle value)
        requests.exchange bridge.READ BEGIN 10 #[] (Time.monotonic-us + 1_000_000)
        result := drive count WARMUP value-size
            (: | request | requests.read request)
            (: | request | requests.validate request)
            (: | handle/int value/ByteArray | requests.written handle value)
        requests.exchange bridge.READ END 10 #[] (Time.monotonic-us + 1_000_000)
        result["mode"] = "rpc-provider"
        print (json.encode result).to-string
      finally:
        critical-do --no-respect-deadline:
          requests.close --error="GATT_PEER_DISCONNECTED"

  on-closed -> none:
    super
    if worker_: worker_.cancel

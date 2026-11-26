// Copyright (C) 2026 Toit contributors.

// The QEMU suite of the device/format2 work: one boot container that runs
// a representative set of programs on the firmware and prints lines that
// must be identical between the format-1/C++ and the format-2/core
// firmwares ("SUITE ..."), plus measurements ("TIME ...", "MEM ...") that
// differ. With QEMU's -icount shift=0 one microsecond of virtual time is
// one thousand guest instructions.

import encoding.json
import esp32
import system
import system.assets
import system.containers
import uuid

import .echo-service
import .richards as richards
import .deltablue as deltablue
import .pystone as pystone

time name/string [block] -> any:
  start := Time.monotonic-us
  result := block.call
  elapsed := Time.monotonic-us - start
  print "TIME $name $elapsed us"
  return result

memory name/string -> none:
  stats := system.process-stats
  print "MEM $name system-free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest $stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]"

find-image name/string -> uuid.Uuid?:
  containers.images.do: | image/containers.ContainerImage |
    if image.name == name: return image.id
  return null

main:
  if esp32.reset-reason == esp32.RESET-DEEPSLEEP:
    print "SUITE woke from deep sleep (wakeup cause $esp32.wakeup-cause)"
    print "SUITE done"
    return

  memory "boot"
  print "SUITE hello from the suite"
  print "SUITE format $(system.platform) $(system.architecture)"

  // Benchmarks (fewer iterations than on hosts; one of each fits easily).
  time "richards": richards.run-richards
  print "SUITE richards ok"
  time "deltablue":
    deltablue.chain-test 50
    deltablue.projection-test 50
  print "SUITE deltablue ok"
  time "pystone": pystone.pystones --loops=2000
  print "SUITE pystone ok"
  json-checksum := time "json": json-bench
  print "SUITE json $json-checksum"
  map-checksum := time "map-set": map-set-bench
  print "SUITE map-set $map-checksum"
  string-checksum := time "strings": string-bench
  print "SUITE strings $string-checksum"

  // GC stress.
  gc-before := system.process-stats[system.STATS-INDEX-GC-COUNT]
  gc-checksum := time "gc-stress": gc-stress
  gc-after := system.process-stats[system.STATS-INDEX-GC-COUNT]
  print "SUITE gc-stress $gc-checksum gcs>0: $(gc-after > gc-before)"
  memory "after-gc"

  // Profiler hook: the trace message must decode; its contents depend on
  // the sampling.
  Profiler.install false
  Profiler.start
  richards.run-richards
  Profiler.stop
  Profiler.report "richards profile" --cutoff=50
  print "SUITE profiler reported"

  // Service calls between containers.
  provider-id := find-image "provider"
  provider := containers.start provider-id
  client := EchoServiceClient
  client.open --timeout=(Duration --s=10)
  print "SUITE service echo $(client.echo [1, "two", 3.5])"
  sum := time "rpc-200":
    s := 0
    200.repeat: s = client.add s it
    s
  print "SUITE service sum $sum"
  client.close
  provider.stop
  print "SUITE provider stopped"

  // Preemption: a CPU-bound container must not starve this process.
  spinner := containers.start (find-image "spinner")
  max-late := 0
  ticks := 0
  spin-start := Time.monotonic-us
  while ticks < 40:
    before := Time.monotonic-us
    sleep --ms=20
    late := Time.monotonic-us - before - 20_000
    if late > max-late: max-late = late
    ticks++
  print "TIME preemption-max-late $max-late us"
  print "SUITE preemption ticks $ticks late<200ms: $(max-late < 200_000)"
  print "SUITE spinner exit $spinner.wait"
  print "TIME spinner $(Time.monotonic-us - spin-start) us"

  // A container that dies with an uncaught exception.
  thrower := containers.start (find-image "thrower")
  print "SUITE thrower exit $thrower.wait"

  // Untrusted containers (assets of this container): install, run, reject.
  memory "before-untrusted"
  decoded := assets.decode
  names := decoded.keys.sort
  names.do: | name/string |
    image/ByteArray := decoded[name]
    id := null
    start := Time.monotonic-us
    exception := catch:
      writer := containers.ContainerImageWriter image.size
      try:
        // In 4 KB chunks, as Jaguar does (see hwinstall.toit).
        List.chunk-up 0 image.size 4096: | from to | writer.write image[from..to]
        id = writer.commit --untrusted
      finally:
        writer.close
    print "TIME install-$name $(Time.monotonic-us - start) us"
    if exception or not id:
      print "SUITE untrusted $name install-failed $exception"
      continue.do
    code := -1
    exception = catch:
      container := containers.start id
      code = container.wait
    print "SUITE untrusted $name exit $code$(exception ? " $exception" : "")"
    catch: containers.uninstall id
  memory "after-untrusted"

  // Deep sleep: the next boot prints the wakeup line.
  print "SUITE deep sleep"
  esp32.deep-sleep (Duration --ms=500)

json-bench -> int:
  data := {
    "name": "device",
    "values": List 40: it * 3,
    "nested": { "a": [1, 2, {"b": "c"}], "d": 3.25, "e": null, "f": true },
  }
  checksum := 0
  30.repeat:
    encoded := json.encode data
    decoded := json.decode encoded
    checksum += encoded.size + decoded["values"].size
  return checksum

map-set-bench -> int:
  map := {:}
  set := {}
  1000.repeat:
    map[it] = it * 2
    set.add "s$(it % 300)"
  sum := 0
  map.do: | k v | sum += v
  500.repeat: map.remove it
  return sum + map.size + set.size

string-bench -> int:
  total := 0
  200.repeat:
    s := "item-$it:$(it * 7)"
    parts := s.split ":"
    total += parts[0].size + (int.parse parts[1]) + (s.index-of "-")
    total += (s.to-ascii-upper.contains "ITEM") ? 1 : 0
  return total

class Node:
  next/Node? := null
  payload/any
  constructor .payload:

gc-stress -> int:
  ring := List 64
  checksum := 0
  6000.repeat: | i |
    kind := i % 4
    object/any := null
    if kind == 0: object = List 16: it + i
    else if kind == 1: object = "string-$i"
    else if kind == 2: object = ByteArray 100: i & 0xff
    else:
      node := Node i
      node.next = Node [i]
      object = node
    ring[i % 64] = object
    checksum = (checksum + i) & 0xfffffff
  ring.do: if it is List: checksum += it.size
  return checksum

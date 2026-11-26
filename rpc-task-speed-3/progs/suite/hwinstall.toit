// Copyright (C) 2026 Toit contributors.

// Free heap at boot and with WiFi connected, then the untrusted installs
// of the assets (time and heap around each), with WiFi still up when
// WIFI is true (the firmware's config must hold the credentials).

import net
import system
import system.assets
import system.containers

memory name/string -> none:
  stats := system.process-stats
  print "MEM $name system-free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest $stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]"

main:
  memory "boot"
  network := null
  exception := catch:
    start := Time.monotonic-us
    network = net.open
    print "TIME wifi-connect $(Time.monotonic-us - start) us"
  if exception: print "WIFI failed $exception"
  else: print "WIFI up $network.address"
  sleep --ms=2000
  memory "wifi-up"
  install-all
  if network:
    network.close
    sleep --ms=1000
    memory "wifi-closed"
  print "SUITE done"

install-all -> none:
  decoded := assets.decode
  decoded.keys.sort.do: | name/string |
    image/ByteArray := decoded[name]
    id := null
    memory "before-$name"
    // hw-perf firmware (TOIT_HW_PERF): counters per install; elsewhere a no-op.
    perf := (catch: Profiler.start) == null
    if perf: print "[hw-perf] begin install-$name"
    start := Time.monotonic-us
    exception := catch:
      writer := containers.ContainerImageWriter image.size
      try:
        // In 4 KB chunks, as Jaguar does: one write of the whole image
        // needs a contiguous buffer of its size in the system process.
        List.chunk-up 0 image.size 4096: | from to | writer.write image[from..to]
        id = writer.commit --untrusted=(not name.starts-with "t-")
      finally:
        writer.close
    elapsed := Time.monotonic-us - start
    if perf: Profiler.stop
    print "TIME install-$name $elapsed us size $image.size"
    if exception or not id:
      print "SUITE untrusted $name install-failed $exception"
      continue.do
    code := -1
    exception = catch:
      start = Time.monotonic-us
      code = (containers.start id).wait
      print "TIME run-$name $(Time.monotonic-us - start) us"
    print "SUITE untrusted $name exit $code$(exception ? " $exception" : "")"
    catch: containers.uninstall id
    memory "after-$name"

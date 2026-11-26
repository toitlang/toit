// Copyright (C) 2026 Toit contributors.

// Installs the untrusted images of its assets one after the other (with
// a firmware built with Kconfig TOIT_TRACE_INSTALL the VM prints the
// verification's time and heap use), runs the accepted ones and
// uninstalls them.

import system
import system.assets
import system.containers

memory name/string -> none:
  stats := system.process-stats
  print "MEM $name system-free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest $stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]"

main:
  memory "boot"
  decoded := assets.decode
  decoded.keys.sort.do: | name/string |
    image/ByteArray := decoded[name]
    id := null
    start := Time.monotonic-us
    exception := catch:
      writer := containers.ContainerImageWriter image.size
      try:
        writer.write image
        // Images named t-* are first-party: installed trusted (as Jaguar
        // installs applications), so they run from the programs partition
        // with the trusted token.
        id = writer.commit --untrusted=(not name.starts-with "t-")
      finally:
        writer.close
    print "TIME install-$name $(Time.monotonic-us - start) us"
    if exception or not id:
      print "SUITE untrusted $name install-failed $exception"
      continue.do
    code := -1
    exception = catch:
      code = (containers.start id).wait
    print "SUITE untrusted $name exit $code$(exception ? " $exception" : "")"
    catch: containers.uninstall id
    memory "after-$name"
  print "SUITE done"

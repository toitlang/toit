// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that sandboxed containers lose first when the system process runs
// out of memory serving a request of trusted code.
//
// When the system process can't allocate for a request it serves (here the
// start of a trusted container; on a device also the WiFi connect, whose
// driver needs about 65 KB), it tried once more after 100 ms and then
// failed the request (system-oom-request-test.toit). Now, for requests of
// trusted code, it then stops the running sandboxed containers one at a
// time (the one that holds the most memory first) and tries again after
// each (with-out-of-memory-retry_ --relieve, system/out_of_memory.toit).
// The stopped sandbox's clients see exit code 243
// (containers.EXIT-EVICTED).
//
// The child VM's system process fails the next 8 attempts of the
// container start (-Xinject_system_oom=spawn:8: the first try and the
// retry): before, the trusted start failed with OUT_OF_MEMORY while the
// sandbox kept running; now the sandbox is stopped and the start succeeds.
// The start of a sandboxed container never stops other sandboxes
// (system-oom-request-test, whose image is installed untrusted).

import expect show *
import system
import .sandbox-util show *

PROGRAM ::= """
main:
  print "system-oom-relief-target ran"
"""

main args:
  run := args[0]
  compiler := args[1]
  sdk := compiler[..compiler.size - "/lib/toit/bin/toit.compile".size]
  toit := "$sdk/bin/toit"
  bits := system.BITS-PER-WORD

  with-tmp-directory: | dir |
    image := build-image toit compiler dir "program" PROGRAM bits

    // Without failures the sandbox keeps running until the driver stops it.
    output := drive dir run image null
    expect-equals ["exit: 0", "sandbox: 0", "system alive"] (outcomes output)

    // Two attempt sequences fail: the sandbox is stopped, the third works.
    output = drive dir run image "spawn:8"
    expect-equals ["exit: 0", "sandbox: 243", "system alive"] (outcomes output)
    expect (output.contains "[out of memory in system process: stopping sandboxed container ")
  print "system-oom-relief-test OK"

drive dir/string run/string image/string injection/string? -> string:
  flags := injection ? ["-Xinject_system_oom=$injection"] : []
  environment := {"TOIT_FLASH_REGISTRY_FILE": "$dir/flash-$(injection or "none").registry"}
  result := run-process [run] + flags + ["tests/sandbox/system-oom-relief-driver.toit", image]
      --environment=environment
      --timeout-ms=120_000
  print result.output
  expect-equals 0 result.exit-code
  return result.output

build-image toit/string compiler/string dir/string name/string source/string bits/int -> string:
  write-file "$dir/$(name).toit" source
  snapshot := "$dir/$(name).snapshot"
  compile-snapshot compiler "$dir/$(name).toit" snapshot
  image := "$dir/$(name).image"
  result := run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
  if result.exit-code != 0: throw "snapshot-to-image failed: $result.output"
  return image

outcomes output/string -> List:
  result := []
  output.split "\n": | line/string |
    if line.starts-with "exit: " or line.starts-with "start failed: " or line.starts-with "sandbox: "
        or line == "system alive":
      result.add line
  return result

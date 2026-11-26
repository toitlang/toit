// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that the system process fails a request it serves for another
// process when it runs out of memory, instead of restarting the device.
//
// Before, any allocation of the system process that still failed after the
// collections restarted the device ("Out of memory in system process"; on
// the host the VM aborts). In 8-hour device soaks that was the main cause of
// restarts: starting an installed container (programs-registry.spawn, after
// an install) in format 1 and format 2. Now the primitives the system
// process serves for others (spawn, image writer, flash registry) fail with
// an out-of-memory error (src/out_of_memory.h), and the system code fails
// the request: the container start fails, the commit fails with
// OUT_OF_MEMORY, the writer can't be opened; each after one more attempt
// (system/out_of_memory.toit). A half-done operation is undone: a commit
// whose allocation can't be read back erases its header.
//
// The child VM's system process fails the next N allocation attempts at one
// site (-Xinject_system_oom=SITE:N, host only; one attempt sequence of a
// primitive is 4 attempts, the retry makes it 8). The installer
// (system-oom-installer.toit) installs an image and starts it, each a second
// time if the first try fails, and the system keeps running.

import expect show *
import host.file
import io show LITTLE-ENDIAN
import system
import uuid
import .sandbox-util show *

PROGRAM ::= """
main:
  print "system-oom-target ran"
"""

PAGE-SIZE ::= 4096

main args:
  run := args[0]
  compiler := args[1]
  sdk := compiler[..compiler.size - "/lib/toit/bin/toit.compile".size]
  toit := "$sdk/bin/toit"
  bits := system.BITS-PER-WORD

  with-tmp-directory: | dir |
    image := build-image toit compiler dir "program" PROGRAM bits

    // No failure.
    output := install dir run image null
    expect-equals ["install: ok", "exit: 0", "images: 1", "system alive"] (outcomes output)

    // The container start: two attempt sequences fail, the start fails and
    // the system keeps running; the second start works.
    output = install dir run image "spawn:8"
    expect-equals ["install: ok", "start failed: OUT_OF_MEMORY", "exit: 0", "images: 1", "system alive"]
        outcomes output
    expect (output.contains "[out of memory in system process: the operation fails, no restart]")
    // One attempt sequence fails: the retry starts the container.
    output = install dir run image "spawn:4"
    expect-equals ["install: ok", "exit: 0", "images: 1", "system alive"] (outcomes output)

    // The commit: the primitive is tried 4 times (COMMIT-OUT-OF-MEMORY-RETRIES_
    // after the first), each an attempt sequence of 4.
    output = install dir run image "commit:16"
    expect-equals ["install failed: OUT_OF_MEMORY", "install: ok", "exit: 0", "images: 1", "system alive"]
        outcomes output
    output = install dir run image "commit:8"
    expect-equals ["install: ok", "exit: 0", "images: 1", "system alive"] (outcomes output)

    // The allocation of a committed image can't be read back (the header
    // page's proxy): the commit is undone and fails. Only the second
    // install's allocation is left in the flash.
    flash := "$dir/header-page.registry"
    output = install dir run image "header-page:8" --flash=flash
    expect-equals ["install failed: OUT_OF_MEMORY", "install: ok", "exit: 0", "images: 1", "system alive"]
        outcomes output
    id := (output.split "install: ")[1][..36]
    expect-equals 1 (count-allocations flash id)

    // The writer's flash reservation.
    output = install dir run image "reserve:8"
    expect-equals ["install failed: OUT_OF_MEMORY", "install: ok", "exit: 0", "images: 1", "system alive"]
        outcomes output

    // A flash bucket (the storage service): the set fails and the bucket
    // still holds what the flash holds (before, the cache took the new value
    // before it was written); the second set works.
    output = install dir run "bucket" "header-page:8"
    expect (output.contains "set: OUT_OF_MEMORY, get: null\n")
    expect (output.contains "set: ok, get: value\n")
    expect (output.contains "system alive")
  print "system-oom-request-test OK"

/** Runs the installer with $image in a child VM and returns its output. */
install dir/string run/string image/string injection/string? --flash/string?=null -> string:
  flags := injection ? ["-Xinject_system_oom=$injection"] : []
  environment := {"TOIT_FLASH_REGISTRY_FILE": flash or "$dir/flash-$(injection or "none").registry"}
  result := run-process [run] + flags + ["tests/sandbox/system-oom-installer.toit", image]
      --environment=environment
      --timeout-ms=120_000
  print result.output
  // Before, the system process aborted the VM.
  expect-equals 0 result.exit-code
  expect-not (result.output.contains "Out of memory in system process; aborting")
  return result.output

/** The installer's outcome lines, with the image id left out. */
outcomes output/string -> List:
  result := []
  output.split "\n": | line/string |
    if line.starts-with "install: ":
      result.add "install: ok"
    else if line.starts-with "install failed: " or line.starts-with "start failed: "
        or line.starts-with "exit: " or line.starts-with "images: " or line == "system alive":
      result.add line
  return result

/** The number of valid allocation headers of the image $id in the flash registry file $path. */
count-allocations path/string id/string -> int:
  bytes := file.read-contents path
  id-bytes := (uuid.Uuid.parse id).to-byte-array
  count := 0
  for offset := 0; offset + PAGE-SIZE <= bytes.size; offset += PAGE-SIZE:
    // The allocation header (src/flash_allocation.h): marker 0xdeadface, the
    // checksum, the id.
    if (LITTLE-ENDIAN.uint32 bytes offset) != 0xdeadface: continue
    if bytes[offset + 8..offset + 24] == id-bytes: count++
  return count

build-image toit/string compiler/string dir/string name/string source/string bits/int -> string:
  write-file "$dir/$(name).toit" source
  snapshot := "$dir/$(name).snapshot"
  compile-snapshot compiler "$dir/$(name).toit" snapshot --untrusted
  image := "$dir/$(name).image"
  result := run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
  if result.exit-code != 0: throw "snapshot-to-image failed: $result.output"
  return image

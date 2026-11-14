// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import host.directory
import host.file
import .host-test

// Proves that a container assertion leaves the system and USB OTA usable.
main argv/List:
  args := options argv ["uploader", "port", "failure-image", "healthy-image", "logs"]
  directory.mkdir --recursive args["logs"]
  upload args args["failure-image"] "$(args["logs"])/container-failure-upload.log" --no-reboot
  capture args "container-failure" "Expected <expected>, but was <deliberate failure>" --check-console
  upload args args["healthy-image"] "$(args["logs"])/after-container-failure-upload.log" --no-reboot
  capture args "after-container-failure" "RP2350 VM/GC/timer smoke: PASS"
  print "container-failure-test: PASS assertion isolation and subsequent OTA"

capture args/Map label/string expected/string --check-console/bool=false:
  console := Console args["port"]
  log := file.Stream.for-write "$(args["logs"])/$(label).log"
  try:
    console.command "TOIT-OTA REBOOT"
    with-timeout --ms=25_000:
      while not console.transcript.contains expected:
        log.out.write console.poll
    expect-not (console.transcript.contains "VM exited")
    if check-console:
      until := now + 2000
      while now < until: log.out.write console.poll
      info := console.info
      log.out.write "\n[host] OTA INFO: $info\n"
      expect-equals 0 info[1]
      expect-equals 4_194_304 info[2]
      expect-not (console.transcript.contains "VM exited")
  finally:
    console.close
    log.close

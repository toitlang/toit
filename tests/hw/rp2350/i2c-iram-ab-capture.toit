// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import host.file
import .host-test

// Opens both consoles before activating a staged RP2350 image.
main argv/List:
  args := options argv ["rp-port", "esp-port", "rp-log", "esp-log"]
      --optional=["seconds", "rp-complete", "esp-complete"]
  seconds := float.parse (args.get "seconds" --if-absent=: "120")
  rp-marker := args.get "rp-complete" --if-absent=: "i2c-jaguar-isr-diagnostic: complete"
  esp-marker := args.get "esp-complete" --if-absent=: "i2c-target-esp32: complete"
  // Preserve the first failure transcript instead of silently replacing it.
  ["rp-log", "esp-log"].do: |key|
    if file.is-file args[key]: throw "Refusing to overwrite $(args[key])"
  rp-log := file.Stream.for-write args["rp-log"]
  esp-log := file.Stream.for-write args["esp-log"]
  rp := null
  esp := null
  try:
    rp = Console args["rp-port"]
    esp = Console args["esp-port"]
    start := now
    rp.command "TOIT-OTA REBOOT"
    rp-log.out.write "[host] sent TOIT-OTA REBOOT\n"
    next-info := start + 3000
    completed-at := null
    while now < start + seconds * 1000:
      capture rp rp-log "RP" start
      capture esp esp-log "ESP" start
      if rp.port and now >= next-info:
        catch: rp.command "TOIT-OTA INFO"
        next-info = now + 2000
      if (rp.transcript.contains rp-marker) and (esp.transcript.contains esp-marker):
        if not completed-at: completed-at = now
        if now - completed-at >= 2000:
          print "i2c-iram-ab-capture: PASS both completion markers"
          return
    throw "Capture timed out before both completion markers"
  finally:
    if rp: rp.close
    if esp: esp.close
    rp-log.close
    esp-log.close

capture console/Console log name/string start/int:
  before := console.disconnects
  text := console.poll --ms=10
  if text.size > 0:
    record := "[$(now - start)ms] $text"
    print "$name: $record"
    log.out.write record
  if console.disconnects != before:
    log.out.write "[$(now - start)ms] serial disconnect\n"

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import host.file
import .host-test

// Exercises native fault images via OTA. Trial images must roll back; validated
// images must restart in their new partition without repeatedly rebooting.
main argv/List:
  args := options argv ["port", "uploader", "image", "fault", "log"] --optional=["validated"]
  fault := args["fault"]
  expect (["abort", "exit", "fatal", "panic", "hardfault", "xip-fault",
      "stack-overflow", "system-oom", "watchdog-hang"].contains fault)
  console := Console args["port"]
  baseline := console.info
  console.close
  expect-equals 0 baseline[1]
  expect-equals 4_194_304 baseline[2]
  validated := args.get "validated" --if-absent=: false
  expected := validated ? 1 - baseline[0] : baseline[0]
  upload args args["image"] "$(args["log"]).upload.log" --no-reboot
  console = Console args["port"]
  log := file.Stream.for-write args["log"]
  try:
    console.command "TOIT-OTA REBOOT"
    deadline := now + 45_000
    probe := now + 2000
    settled := null
    fault-seen := null
    while now < deadline:
      text := console.poll
      if text.size > 0:
        print text
        log.out.write text
      if console.port and now >= probe:
        catch: console.command "TOIT-OTA INFO"
        probe = now + 1000
      marker := "[test] injecting native $fault"
      if not console.transcript.contains marker: continue
      if not fault-seen: fault-seen = now
      after-fault := (console.transcript.split marker)[1]
      boot := "[toit] boot partition=$expected type=0 trial/update=0"
      info := "TOIT-OTA INFO 1 $expected 0 4194304"
      if not (after-fault.contains boot) or not (after-fault.contains info) or console.disconnects < 2:
        continue
      if fault == "watchdog-hang" and not (after-fault.contains "watchdog-hang-rp2350: PASS recovered from native interrupt-off hang"):
        continue
      if fault == "system-oom":
        before-recovery := (after-fault.split boot)[0]
        expect (before-recovery.contains "RP2350 heap: out of memory")
        expect (before-recovery.contains "[toit] native panic")
      if not settled:
        settled = now
        elapsed := settled - fault-seen
        log.out.write "\n[host] confirmed recovery $elapsed ms after fault marker\n"
        // Distinguish fast fault recovery from the ROM's later trial watchdog.
        expect (elapsed <= 8000)
      if now - settled >= 4000:
        expect-equals 2 console.disconnects
        expect-equals 2 (after-fault.split "[toit] RP2350 VM starting").size
        print "native-failure-test: PASS $(validated ? "confirmed restart" : "trial rollback")"
        return
    throw "Did not observe fault, reset, and confirmed recovery"
  finally:
    console.close
    log.close

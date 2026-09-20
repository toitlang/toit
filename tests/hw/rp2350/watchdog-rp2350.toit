// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import rp2350
import rp2350.watchdog
import system.firmware
import system.storage

/**
Tests the application watchdog and its separation from the ROM trial timer.

Supply a fresh `watchdog-token` in the envelope config. With `leave-trial`
  set to true, the test exercises feed/stop without arming and waits for the
  ROM's timeout to roll back. Otherwise it validates, tests feeding/stopping,
  expires the watchdog, then performs a software reset to check reset causes.
*/

main:
  if firmware.config["leave-trial"]:
    expect-throw "INVALID_STATE":
      watchdog.watchdog-start --timeout=(Duration --s=1)
    print "watchdog-rp2350: preserving ROM trial timer"
    while true:
      watchdog.watchdog-feed
      watchdog.watchdog-stop
      sleep --ms=100

  token/string := firmware.config["watchdog-token"]
  bucket := storage.Bucket.open --flash "toit-rp2350-test/watchdog"
  phase := "initial"
  try:
    if (bucket.get "token") == token: phase = bucket["phase"]
    if phase == "after-watchdog":
      expect watchdog.caused-reset
      bucket["phase"] = "after-software-reset"
    else if phase == "initial":
      expect (not watchdog.caused-reset)
  finally:
    bucket.close

  firmware.validate
  if phase == "after-software-reset":
    expect (not watchdog.caused-reset)
    print "watchdog-rp2350: PASS feed, stop, expiration, and software reset causes"
    return
  if phase == "after-watchdog":
    // Reset cause is a boot snapshot, not the live scratch-register value.
    watchdog.watchdog-start --timeout=(Duration --s=1)
    expect watchdog.caused-reset
    watchdog.watchdog-stop
    expect watchdog.caused-reset
    print "watchdog-rp2350: expiration observed; requesting software reset"
    rp2350.reset
    unreachable

  [-1, 0, 999, 16_001].do: | milliseconds/int |
    expect-throw "INVALID_ARGUMENT":
      watchdog.watchdog-start --timeout=(Duration --ms=milliseconds)
  watchdog.watchdog-start --timeout=watchdog.WATCHDOG-MAX-TIMEOUT
  watchdog.watchdog-start --timeout=(Duration --s=1)
  10.repeat:
    sleep --ms=250
    watchdog.watchdog-feed
  print "watchdog-rp2350: feeding for longer than the timeout PASS"
  watchdog.watchdog-stop
  watchdog.watchdog-stop
  sleep --ms=1250
  print "watchdog-rp2350: stopped watchdog stayed inactive PASS"
  bucket = storage.Bucket.open --flash "toit-rp2350-test/watchdog"
  try:
    bucket["token"] = token
    bucket["phase"] = "after-watchdog"
  finally:
    bucket.close
  watchdog.watchdog-start --timeout=(Duration --s=1)
  // Idempotent validation must not call ROM again and disable this timer.
  firmware.validate
  print "watchdog-rp2350: waiting for application watchdog expiration"
  sleep --ms=5000
  throw "watchdog failed to reset the chip"

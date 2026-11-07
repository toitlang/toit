// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import .initialize show Platform

main:
  error := catch --trace:
    platform := Platform
    platform.start-containers
    task::
      result := platform.containers.wait-until-done
      if result != 0: exit result
  if error:
    print "RP2040 system startup failed: $error"
    exit 1
  // Watchdog and recovery remain available after applications finish.
  // Standard input belongs entirely to application readers.
  while true:
    if recovery-requested_: exit 0
    feed-system-watchdog_
    sleep --ms=500

feed-system-watchdog_ -> none:
  #primitive.rp2040.system-watchdog-feed

recovery-requested_ -> bool:
  #primitive.rp2040.recovery-requested

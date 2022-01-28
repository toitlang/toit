// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show StateTracker

tracker := StateTracker

main:
  task:: changer
  task:: listener

changer:
  tracker["hi"] = "there"
  tracker.increment "counter"
  sleep --ms=100
  tracker.increment "counter"
  sleep --ms=100
  tracker.decrement "counter" --by=2
  sleep --ms=100
  tracker.log "foo"
  sleep --ms=100
  tracker.log "bar"
  tracker.log "fizz"
  tracker.log "buzz"
  tracker.log "toit"
  tracker.log "buzz2"
  tracker.log "buzz3"
  tracker.log "buzz4"
  sleep --ms=100
  tracker.decrement "counter" --by=2
  tracker.log "toit2"

listener:
  state := {"hi": null, "log": null, "counter": 0}
  while true:
    state = tracker.wait_for_new_state state
    if state.contains "hi":
      expect_equals "there" state["hi"]
      print "Hi there"
      print "count $state["counter"]"
      log_lines := state["log"]
      if log_lines:
        print "*"
        print
          log_lines.join "\n"
        print "#"
        if log_lines[log_lines.size - 1] == "toit2":
          // There are only 8 spaces in the log, so we expect the original
          // "foo" to have scrolled out of the buffer by now.
          expect
            not log_lines.any: it == "foo"
          return

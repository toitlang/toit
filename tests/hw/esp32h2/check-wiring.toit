// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Bootstrap check: both boards run the C fixture before the Toit port is trusted.
import encoding.json
import expect show *
import host.file
import uart

WIRES ::= {0: 12, 1: 14, 2: 27, 3: 26, 4: 32, 5: 35, 10: 13}

class Board:
  port_/uart.HostPort

  constructor path/string:
    port_ = uart.HostPort path --baud-rate=115200
    port_.set-control-flags 0

  command text/string -> string:
    return with-timeout --ms=3000:
      port_.out.write "$text\n"
      port_.out.flush
      while true:
        line := port_.in.read-line
        if not line: throw "Fixture closed"
        line = line.trim
        if line == "RIG ERROR": throw "Fixture rejected $text"
        if line.starts-with "RIG READY": continue
        if line.starts-with "RIG ": return line
      unreachable

  levels -> int:
    reply := command "READ"
    expect (reply.starts-with "RIG READ ")
    return int.parse reply[9..] --radix=16

  close:
    try:
      command "RESET"
    finally:
      port_.close

main args/List:
  if args.size != 6:
    throw "Usage: --h2-port PORT --helper-port PORT --output FILE"
  options := {:}
  for i := 0; i < args.size; i += 2: options[args[i]] = args[i + 1]
  report := {"checks": [], "passed": false}
  failures := []
  h2/Board? := null
  helper/Board? := null
  check := :: | name actual expected |
    passed := actual == expected
    if actual is Map and expected is Map:
      passed = actual.size == expected.size
      expected.do: | key value |
        if (actual.get key) != value: passed = false
    report["checks"].add {"name": name, "actual": actual, "expected": expected, "passed": passed}
    print "$(passed ? "PASS" : "FAIL") $name: $actual"
    if not passed: failures.add name
  try:
    h2 = Board options["--h2-port"]
    helper = Board options["--helper-port"]
    sleep --ms=1000
    report["h2"] = h2.command "INFO"
    report["helper"] = helper.command "INFO"
    expect (report["h2"].contains "INFO esp32h2 ")
    expect (report["helper"].contains "INFO esp32 ")
    [false, true].do: | reverse |
      h2.command "RESET"
      helper.command "RESET"
      source := reverse ? helper : h2
      observer := reverse ? h2 : helper
      mapping := reverse ? {:} : WIRES
      if reverse: WIRES.do: | pin peer | mapping[peer] = pin
      mapping.values.do: | pin |
        observer.command "INPUT $pin $(pin == 35 ? 0 : 1)"
      mapping.do: | pin peer |
        if reverse and pin == 35: continue.do
        [1, 0, 1].do: | level |
          source.command "OD $pin $level"
          sleep --ms=30
          levels := observer.levels
          observed := {:}
          expected := {:}
          mapping.values.do: | p |
            if p != 35 or peer == 35:
              observed["$p"] = (levels >> p) & 1
              expected["$p"] = p == peer ? level : 1
          check.call "$(reverse ? "ESP32->H2" : "H2->ESP32") $pin->$peer OD=$level" observed expected
        source.command "INPUT $pin 0"
    h2.command "RESET"
    helper.command "RESET"
    [[0, 0, 0], [0, 1, 1], [1, 0, 1], [2, 1, 0]].do: | config |
      pull := config[0]
      bias := config[1]
      expected := config[2]
      h2.command "INPUT 4 $pull"
      helper.command "DRIVE 33 $bias"
      sleep --ms=100
      check.call "resistor pull=$pull bias=$bias"
          [(h2.levels >> 4) & 1, (helper.levels >> 32) & 1]
          [expected, expected]
    if not failures.is-empty: throw "Wiring failures: $failures"
    report["passed"] = true
  finally:
    // Try both cleanups even if either bridge has stopped responding.
    if h2: catch: h2.close
    if helper: catch: helper.close
    file.write-contents --path=options["--output"] (json.encode report)

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.hex
import expect show *
import io
import .ble-hardware.soak-check as checker

main:
  source := logs
  host/string := source[0]
  board/string := source[1]
  result := check host board
  expect result["log_checks_pass"]
  expect (not result["duration_24h"] and not result["adapter_restoration_verified"])
  expect-throw "SOAK_CHECK: Host duration too short": check host board --minimum-seconds=86400
  long-host := host.replace "elapsed-us=2000000" "elapsed-us=86400000000"
  expect (check long-host board --minimum-seconds=86400)["duration_24h"]
  lines := host.split "\n"
  cases := [
    [host, board, 1],
    [host + "EXCEPTION failed\n", board, 0],
    [(lines[1..].join "\n"), board, 0],
    [lines[0] + "\n" + host, board, 0],
    [host.replace "sequence=7" "sequence=8", board, 0],
    [host.replace "00000000546f6974484349" "ffffffff546f6974484349", board, 0],
    [host, board.replace "00000000546f6974484349" "ffffffff546f6974484349", 0],
    [host.replace "elapsed-us=1400000" "elapsed-us=1", board, 0],
    [(host.split "ECHO_COMPLETE")[0], board, 0],
    [host + lines[4] + "\n", board, 0],
    [lines[4] + "\n" + host, board, 0],
    [host.replace "count=20" "count=19", board, 0],
    [host.replace "full-gcs=2" "full-gcs=0", board, 0],
    [host, board.replace "retained=1" "retained=0", 0],
    [host, board.replace "validated=20" "validated=19", 0],
    [host, board.replace "reads=2" "reads=1", 0],
    [host, board.replace "LOCAL_COMMAND_PROVIDER COMPLETE" "", 0],
    [host, "LOCAL_COMMAND_PROVIDER COMPLETE\n" + board, 0],
    [host.replace ",2,2]" ",2,0]", board, 0],
    [host.replace "[1,2,3,4,5,6,7,8,9,2,2]" "null", board, 0],
    [host.replace ",2,2]" ",2,true]", board, 0],
    [host, board.replace "BLE_SERVICE_APP process-stats=[1,2,3,4,5,6,7,8,9,2,2]\n" "", 0],
    [host.replace "count=20" "count=19 count=20", board, 0],
    [host.replace "sequence=7" "sequence=-7", board, 0],
    [lines[5] + "\n" + host, board, 0],
  ]
  cases.do: | row/List |
    error := catch: check row[0] row[1] --exit-code=row[2]
    expect (error is string and error.starts-with "SOAK_CHECK:")
  expect-throw "SOAK_CHECK: Invalid expected limits":
    checker.check host board --count=1000001 --host-exit-code=0

check host/string board/string --minimum-seconds/int=2 --exit-code/int=0 -> Map:
  return checker.check host board --count=20 --host-every=7 --board-every=7
      --minimum-seconds=minimum-seconds
      --host-exit-code=exit-code

logs -> List:
  host := []
  board := []
  [0, 7, 14, 19].do: | sequence/int |
    bytes := ByteArray 4
    io.LITTLE-ENDIAN.put-uint32 bytes 0 sequence
    data := (hex.encode bytes) + "546f6974484349"
    host.add "ECHO sequence=$sequence data=$data elapsed-us=$(sequence * 100000)"
    board.add "BLE_SERVICE_APP ECHO count=$(sequence + 1) data=$data elapsed-us=$(sequence * 97000)"
  host.add "ECHO_COMPLETE count=20 full-gcs=2 retained=1 elapsed-us=2000000"
  host.add "process-stats=[1,2,3,4,5,6,7,8,9,2,2]"
  board.add "BLE_SERVICE_APP COMPLETE count=20 reads=2 validated=20 full-gcs=2 retained=1 elapsed-us=1940000"
  board.add "BLE_SERVICE_APP process-stats=[1,2,3,4,5,6,7,8,9,2,2]"
  board.add "LOCAL_COMMAND_PROVIDER COMPLETE"
  return [(host.join "\n") + "\n", (board.join "\n") + "\n"]

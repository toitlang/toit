// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.hex
import expect show *
import io
import .ble-hardware.reconnect-check as checker

main:
  board-checks
  source := logs
  host/string := source[0]
  board/string := source[1]
  result := checker.check host board --cycles=2 --warmup=1 --host-exit-code=0
  expect result["logs_pass"]
  expect-equals 30 result["echoes"]
  expect-equals 50000 result["board_minimum_free"]
  expect (not result["adapter_restoration_verified"])
  converted := checker.check (host.replace "\n" "\r\n") board
      --cycles=2
      --warmup=1
      --host-exit-code=0
  result.do: | key value | expect-equals value converted[key]
  cases := [
    [host, board, 1],
    [host + "EXCEPTION error\n", board, 0],
    [host.replace "cycle=2" "cycle=1", board, 0],
    [host.replace "descriptors=8 live=1010" "descriptors=9 live=1010", board, 0],
    [host.replace "maximum=1020" "maximum=1000", board, 0],
    [host + "RECONNECT_COMPLETE cycles=2 warmup=1 echoes=30 baseline=1000 minimum=1000 maximum=1020 descriptors=8\n", board, 0],
    [host, board.replace "00000000546f6974484349" "ffffffff546f6974484349", 0],
    [host, board.replace "full-gcs=1" "full-gcs=0", 0],
    [host, board.replace "hci-during-read=1" "hci-during-read=0", 0],
    [host, board.replace "VHCI_RECONNECT cycle=2" "VHCI_RECONNECT cycle=1", 0],
    [host, board.replace "allocated=2000" "allocated=7000", 0],
    [host, board.replace "compacting-gcs=2" "compacting-gcs=0", 0],
    [host, board.replace "VHCI_RECONNECT COMPLETE cycles=2 warmup=1 baseline=2000 maximum=2000\n" "", 0],
    [host, "VHCI_RECONNECT COMPLETE cycles=2 warmup=1 baseline=2000 maximum=2000\n" + board, 0],
    [host.replace "live=1020" "live=-1020", board, 0],
    [host.replace "live=1020" "live=1020 extra=1", board, 0],
    [host.replace "cycle=1" "cycle=", board, 0],
    [host, board.replace "data=00000000546f6974484349" "data=00000000546F6974484349", 0],
  ]
  cases.do: | row/List |
    error := catch: checker.check row[0] row[1] --cycles=2 --warmup=1 --host-exit-code=row[2]
    expect (error is string and error.starts-with "RECONNECT_CHECK:")

board-checks:
  sleep-line := "[toit] INFO: entering deep sleep without wakeup time\n"
  central := [
    "VHCI_RECONNECT_CENTRAL cycle=1 live=1020 free=50000 largest=20000 compacting-gcs=1\n",
    "VHCI_RECONNECT_CENTRAL cycle=2 live=1010 free=50000 largest=20000 compacting-gcs=2\n",
    "VHCI_RECONNECT_CENTRAL COMPLETE cycles=2 warmup=1 echoes=30 baseline=1000 minimum=1000 maximum=1020\n",
    sleep-line,
  ].join ""

  peer := logs[1] + sleep-line
  result := checker.check-boards central peer --cycles=2 --warmup=1
  expect-equals 1020 result["central_maximum"]
  footer := "\nInterrupt received, shutting down gracefully...\nError: context canceled\n"
  expect (checker.check-boards (central + footer) (peer + footer) --cycles=2 --warmup=1)["logs_pass"]
  [
    central.replace "cycle=2" "cycle=1",
    central.replace "maximum=1020" "maximum=1021",
    central.replace "compacting-gcs=2" "compacting-gcs=0",
    central.replace "largest=20000" "largest=50001",
    central.replace sleep-line "",
    central + sleep-line,
    central + "unexpected output\n",
    central + "Guru Meditation\n",
    central.replace "1020" "6000",
    central.replace "cycle=2 live=1010" "cycle=2 live=-1010",
  ].do: | invalid/string |
    error := catch: checker.check-boards invalid peer --cycles=2 --warmup=1
    expect (error is string and error.starts-with "RECONNECT_CHECK:")
  error := catch: checker.check-boards central (peer.replace sleep-line "") --cycles=2 --warmup=1
  expect (error is string and error.starts-with "RECONNECT_CHECK:")

logs -> List:
  host := [
    "RECONNECT cycle=1 descriptors=8 live=1020\n",
    "RECONNECT cycle=2 descriptors=8 live=1010\n",
    "RECONNECT_COMPLETE cycles=2 warmup=1 echoes=30 baseline=1000 minimum=1000 maximum=1020 descriptors=8\n",
  ].join ""
  board := []
  3.repeat: | cycle/int |
    10.repeat: | index/int |
      bytes := ByteArray 4
      io.LITTLE-ENDIAN.put-uint32 bytes 0 (cycle * 10 + index)
      board.add "GATT_SERVER ECHO count=$(index + 1) data=$(hex.encode bytes)546f6974484349"
    board.add "GATT_SERVER HANDLERS reads=2 validated=10 heartbeats=2 hci-during-read=1"
    board.add "GATT_SERVER COMPLETE count=10 full-gcs=1 retained=1"
    board.add "VHCI_RECONNECT cycle=$cycle allocated=2000 free=50000 largest=20000 compacting-gcs=$cycle"
  board.add "VHCI_RECONNECT COMPLETE cycles=2 warmup=1 baseline=2000 maximum=2000"
  return [host, (board.join "\n") + "\n"]

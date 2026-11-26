// Copyright (C) 2026 Toit contributors.

// WiFi RX throughput: connects to the host (scripts/rx.sh: socat sends
// 1 MB of zeros per connection on port 7998), reads until the host
// closes, five times; "RX bytes us kbytes/s" per run, then "RX done".

import net
import net.tcp
import system

HOST ::= "192.168.77.248"
PORT ::= 7998
RUNS ::= 5

main:
  network := net.open
  print "RX platform $(system.platform) $(system.architecture)"
  rates := []
  RUNS.repeat:
    socket/tcp.Socket := network.tcp-connect HOST PORT
    reader := socket.in
    bytes := 0
    start := Time.monotonic-us
    while data := reader.read: bytes += data.size
    elapsed := Time.monotonic-us - start
    socket.close
    rate := bytes * 1_000 / elapsed  // KB/s (1000 bytes per KB).
    rates.add rate
    print "RX $bytes $elapsed $rate"
    sleep --ms=200
  sorted := rates.sort
  print "RX median $sorted[RUNS / 2] min $sorted[0] max $sorted[RUNS - 1]"
  network.close
  print "RX done"

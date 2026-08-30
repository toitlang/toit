// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.modules.tcp
import system

TRANSFER-SIZES ::= [
  173_025,
  245_688,
  1_212_346,
  8,
  63,
  1_390_176,
  168_486,
  45,
  23_417_108,
]

TRANSFER-DELAYS-MS ::= [
  0,
  150,
  675,
  126,
  1,
  0,
  1,
  1,
  0,
]

main args:
  if args.size != 2: throw "EXPECTED_MODE_AND_PORT"
  port := int.parse args[1]
  network := net.open
  if args[0] == "server":
    run-server network port
  else if args[0] == "client":
    run-client network port
  else:
    throw "UNKNOWN_MODE"

run-server network/net.Client port/int:
  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" port
  print "TCP_CLAMP_REPRO ready port=$port"

  socket := server.accept
  retained := [ByteArray 52_000_000]
  TRANSFER-SIZES.size.repeat: | index |
    started := Time.monotonic-us
    body := read-exactly socket TRANSFER-SIZES[index]
    retained.add body
    elapsed := Time.monotonic-us - started
    print "TCP_CLAMP_REPRO transfer=$index size=$body.size elapsed_us=$elapsed window_size=$(socket.window-size)"
    socket.out.write (ByteArray 42)

  socket.close
  server.close

run-client network/net.Client port/int:
  socket := tcp.TcpSocket network
  socket.connect "127.0.0.1" port
  TRANSFER-SIZES.size.repeat: | index |
    delay := TRANSFER-DELAYS-MS[index]
    if delay: sleep --ms=delay
    socket.out.write (ByteArray TRANSFER-SIZES[index])
    read-exactly socket 42
  socket.out.close
  socket.close

read-exactly socket size/int -> ByteArray:
  result := ByteArray size
  offset := 0
  while offset < size:
    chunk := socket.in.read
    if chunk == null: throw "UNEXPECTED_END_OF_STREAM"
    if offset + chunk.size > size: throw "UNEXPECTED_EXTRA_DATA"
    result.replace offset chunk
    offset += chunk.size
  return result

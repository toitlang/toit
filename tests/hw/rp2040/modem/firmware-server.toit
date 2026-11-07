// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import io
import net.tcp as tcp
import system
import zlib

// Deliberately supports only the three fixed paths used by the OTA regression.
serve socket/tcp.Socket compressed/ByteArray size/int
    --window-size/int=32768 --diagnose-memory/bool=false:
  inflater := zlib.GzipDecoder --window-size=window-size
  feeder := task::
    try:
      inflater.out.write compressed
    finally:
      inflater.out.close
  try:
    serve-body socket inflater.in size --diagnose-memory=diagnose-memory
  finally:
    feeder.cancel
    inflater.in.close
    inflater.out.close

// Keeps HTTP framing and 256-byte writes while removing gzip work and history.
serve-pattern socket/tcp.Socket size/int:
  serve-body socket (PatternReader size) size

class PatternReader extends io.Reader:
  size/int
  position/int := 0
  constructor .size:
  read_ -> ByteArray?:
    if position == size: return null
    count := min 256 (size - position)
    result := ByteArray count: ((position + it) * 31 + 19) & 0xff
    position += count
    return result

serve-body socket/tcp.Socket body/io.Reader size/int --diagnose-memory/bool=false:
  print "RP2040 WIFI PEER firmware accepted $socket.peer-address"
  last-progress := Time.monotonic-us
  phase := "headers"
  sent := 0
  observer/Task? := null
  if diagnose-memory:
    observer = task::
      while true:
        sleep --ms=10_000
        if Time.monotonic-us - last-progress < 10_000_000: continue
        before := system.process-stats
        after := system.process-stats --gc
        print "RP2040 HTTP memory probe: phase=$phase sent=$sent free=$(before[7])->$(after[7]) largest=$(before[8])->$(after[8])"
  try:
    with-timeout --ms=300_000:
      request := line socket.in
      print "RP2040 WIFI PEER firmware request $request"
      parts := request.split " "
      if parts.size != 3 or parts[0] != "GET": throw "Invalid fixture request"
      path/string := parts[1]
      if not ["/firmware.bin", "/truncated.bin", "/corrupt.bin"].contains path:
        throw "Unknown fixture path"
      headers := 0
      while not (line socket.in).is-empty:
        headers++
        if headers > 32: throw "Too many request headers"
      socket.out.write "HTTP/1.1 200 OK\r\nContent-Length: $size\r\nConnection: close\r\n\r\n"
      limit := path == "/truncated.bin" ? min size 4097 : size
      from := 0
      while from < limit:
        phase = "inflate"
        bytes := body.read --max-size=(min 1024 (limit - from))
        if not bytes: throw "Incomplete fixture asset"
        if path == "/corrupt.bin" and from == 0:
          bytes = bytes.copy
          bytes[0] ^= 1
        phase = "write"
        socket.out.write bytes
        from += bytes.size
        sent = from
        if diagnose-memory:
          last-progress = Time.monotonic-us
      print "RP2040 WIFI PEER firmware $path: sent $limit bytes"
  finally:
    if observer: observer.cancel
    socket.close
    print "RP2040 WIFI PEER firmware socket closed after $sent body bytes, phase=$phase"

line reader/io.Reader -> string:
  bytes := #[]
  while true:
    byte := reader.read-byte
    if byte == '\n': return bytes.to-string.trim
    if bytes.size >= 1024: throw "Request line too long"
    bytes += #[byte]

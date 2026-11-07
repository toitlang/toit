// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.base.at as at
import io
import log
import monitor show Channel
import system
import system.assets
import uart

// Acceptance probe for the prepared ESP-AT 2.2 candidate. Deliberately separate
// from the NONOS adapter until the actual binary framing is verified.
main:
  selected := assets.decode.get "at2-test"
  selection := selected ? selected.to-string : "all"
  if not ["all", "passive", "queued", "queued-large", "queued-large-escaped", "sendex", "sendex-binary"].contains selection: throw "INVALID_ARGUMENT"
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  output := SplitWriter port.out
  session := at.Session port.in output
      --logger=(log.default.with-level log.INFO-LEVEL)
      --command-terminator=("\r\n".to-byte-array)
      --data-marker='>'
  incoming := Channel 16
  notifications := Channel 16
  passive := false
  session.add-ok-termination "SEND OK"
  session.add-error-termination "SEND FAIL"
  session.add-error-termination "SEND Canceled"
  session.add-error-termination "FAIL"
  session.add-response-parser "+IPD" --prefix :: | reader/io.Reader |
    check-equals ',' reader.read-byte
    if passive:
      count := int.parse (reader.read-bytes-up-to '\r').to-string
      check (count > 0)
      [count]
    else:
      count := int.parse (reader.read-bytes-up-to ':').to-string
      check (0 < count <= 2048)
      [reader.read-bytes count]
  session.register-urc "+IPD" :: | parts |
    if passive: notifications.send parts.first
    else: incoming.send parts.first
  session.add-response-parser "+CIPRECVDATA" --prefix :: | reader/io.Reader |
    check-equals ':' reader.read-byte
    count := int.parse (reader.read-bytes-up-to ',').to-string
    check (0 <= count <= 1460)
    ip := (reader.read-bytes-up-to ',').to-string
    remote-port := int.parse (reader.read-bytes-up-to ',').to-string
    check-equals "\"200.200.200.1\"" ip
    check-equals 4242 remote-port
    [reader.read-bytes count]
  completed := false
  try:
    session.action ""
    session.action "E0"
    version := session.action "+GMR"
    print version
    check (version.responses.first.first.starts-with "AT version:2.")
    session.set "+SYSSTORE" [0]
    session.set "+CWMODE" [1]
    session.set "+CWJAP" ["toit-rp2040-test", "pico-bringup-test"]
        --timeout=(Duration --s=30)
    // A previous failed probe may leave a single-connection UDP link open.
    // CIPCLOSE=5 only closes links in multiple-connection mode.
    if (session.read "+CIPMUX").single.first == 0:
      session.action "+CIPCLOSE" --no-check
    else:
      session.set "+CIPCLOSE" [5] --no-check
    session.set "+CIPMUX" [0]
    session.set "+CIPMODE" [0]
    session.set "+CIPDINFO" [0]
    session.set "+CIPRECVMODE" [0]
    print "ESP-AT 2 setup: READY"
    if ["all", "sendex", "sendex-binary"].contains selection:
      ["TCP", "UDP"].do: | protocol/string |
        session.set "+CIPSTART" [protocol, "200.200.200.1", 4242]
            --timeout=(Duration --s=10)
        payloads := [
          "+++".to-byte-array,
          "\r\nAT+RST\r\n".to-byte-array,
          (ByteArray 1460: it & 0xff),
          (ByteArray 1460 --initial='+'),
        ]
        (selection == "all" ? payloads : []).do: | payload/ByteArray |
          with-timeout --ms=5000:
            session.send
              at.Command.set "+CIPSEND" --parameters=[payload.size]
                  --data=payload
                  --ok-before-data
            check-echo incoming payload protocol
            system.process-stats --gc
        if selection == "sendex-binary":
          payloads.add (ByteArray 1460 --initial='\\')
          payloads.add #[ '\\', '0', 0, '\\', '+', '+', '+', '\\' ]
          // Escape plus signs as well as backslashes: no UART batch can then
          // equal the modem's literal three-plus abort sequence.
          payloads.do: | payload/ByteArray |
            send-escaped session output payload
            with-timeout --ms=5000: check-echo incoming payload protocol
            system.process-stats --gc
            print "ESP-AT 2 $protocol escaped binary $(payload.size): PASS"
        // Force the escape pair into separate UART batches. NONOS adds an
        // extra backslash here; a continuous encoding test misses that defect.
        output.armed = true
        with-timeout --ms=5000:
          session.send
            at.Command.set "+CIPSENDEX" --parameters=[2048]
                --data=#[ 'A', '\\', '\\', 'B', '\\', '0' ]
                --ok-before-data
          check-echo incoming #[ 'A', '\\', 'B' ] protocol
        check (not output.armed)
        session.action "+CIPCLOSE"
        print "ESP-AT 2 $protocol split escape: PASS"
    if selection != "sendex" and selection != "sendex-binary":
      passive = true
      session.set "+CIPDINFO" [1]
      session.set "+CIPRECVMODE" [1]
      if selection == "all" or selection == "passive":
        ["TCP", "UDP"].do: | protocol/string |
          session.set "+CIPSTART" [protocol, "200.200.200.1", 4242]
              --timeout=(Duration --s=10)
          payload := ByteArray 513: (it * 37) & 0xff
          with-timeout --ms=5000:
            session.send
              at.Command.set "+CIPSEND" --parameters=[payload.size]
                  --data=payload
                  --ok-before-data
            received := 0
            while received < payload.size:
              notifications.receive
              result := session.set "+CIPRECVDATA" [1460]
              bytes/ByteArray := result.single.first
              if protocol == "UDP": check-equals payload.size bytes.size
              check-equals payload[received..received + bytes.size] bytes
              received += bytes.size
          session.action "+CIPCLOSE"
          print "ESP-AT 2 $protocol passive binary and metadata: PASS"
      check-queued-udp session output
          --large-only=(selection == "queued-large" or selection == "queued-large-escaped")
          --escaped=(selection == "queued-large-escaped")
    completed = true
  finally:
    try:
      print "AT2 probe: Pico UART errors=$(port.errors)"
      if not completed:
        if session.is-closed:
          print "AT2 probe: transport unsynchronized; modem power-cycle required"
        else:
          // A completed modem error or payload assertion leaves the command
          // parser usable. Do not pad unknown modem state with filler bytes.
          error := catch:
            with-timeout --ms=3000: session.action "+RST"
          if error: print "AT2 probe: reset not acknowledged: $error"
          else: print "AT2 probe: reset acknowledged"
    finally:
      try:
        session.close
      finally:
        port.close
  if selection == "all": print "RP2040 ESP8285 AT2 acceptance: PASS"
  else: print "RP2040 ESP8285 AT2 $selection: PASS"

check-queued-udp session/at.Session output/SplitWriter
    --large-only/bool=false --escaped/bool=false:
  // This candidate reports the aggregate queued byte count. Wait for both
  // echoes before pulling: sending and immediately reading one datagram
  // cannot reveal concatenation or truncation of a following datagram.
  // A firmware with first-datagram CIPRECVLEN semantics needs a different
  // queue barrier; a timeout here is not evidence of concatenation.
  pairs := large-only ? [[1009, 907]] : [[97, 211], [1009, 907]]
  pairs.do: | sizes/List |
    session.set "+CIPSTART" ["UDP", "200.200.200.1", 4242]
        --timeout=(Duration --s=10)
    payloads := sizes.map: | size/int |
      ByteArray size: (it * 37 + size) & 0xff
    with-timeout --ms=(escaped ? 30_000 : 5000):
      payloads.do: | payload/ByteArray |
        print "ESP-AT 2 UDP queued: sending $(payload.size) bytes"
        if escaped:
          send-escaped session output payload
        else:
          session.send
            at.Command.set "+CIPSEND" --parameters=[payload.size]
                --data=payload
                --ok-before-data
        print "ESP-AT 2 UDP queued: send acknowledged"
      total/int := sizes[0] + sizes[1]
      while true:
        pending := session.read "+CIPRECVLEN"
        count/int := pending.single.first
        if count == total: break
        check (0 <= count < total)
        sleep --ms=10
      print "ESP-AT 2 UDP queued: lengths=$sizes pending=$total"
      payloads.do: | payload/ByteArray |
        result := session.set "+CIPRECVDATA" [1460]
        bytes/ByteArray := result.single.first
        print "ESP-AT 2 UDP pull: expected=$(payload.size) actual=$(bytes.size)"
        if bytes.size != payload.size:
          combined := io.Buffer
          payloads.do: combined.write it
          matches := bytes.size <= combined.size and bytes == combined.bytes[0..bytes.size]
          pending := session.read "+CIPRECVLEN"
          print "ESP-AT 2 UDP boundary failure: matches-concatenated-prefix=$matches remaining=$(pending.single.first)"
        check-equals payload.size bytes.size
        check-equals payload bytes
      pending := session.read "+CIPRECVLEN"
      check-equals 0 pending.single.first
    session.action "+CIPCLOSE"
  print "ESP-AT 2 UDP queued datagram boundaries: PASS"

send-escaped session/at.Session output/SplitWriter payload/ByteArray:
  encoded := io.Buffer
  payload.do:
    if it == '+' or it == '\\': encoded.write-byte '\\'
    encoded.write-byte it
  encoded.write #[ '\\', '0' ]
  output.chunk-size = 3
  try:
    with-timeout --ms=15_000:
      session.send
        at.Command.set "+CIPSENDEX" --parameters=[2048]
            --data=encoded.bytes
            --ok-before-data
            --timeout=(Duration --s=12)
  finally:
    output.chunk-size = 0

check-echo incoming/Channel payload/ByteArray protocol/string:
  received := 0
  while received < payload.size:
    bytes/ByteArray := incoming.receive
    if protocol == "UDP": check-equals payload.size bytes.size
    check (received + bytes.size <= payload.size)
    check-equals payload[received..received + bytes.size] bytes
    received += bytes.size

class SplitWriter extends io.Writer:
  output_/io.Writer
  armed := false
  chunk-size := 0
  constructor .output_:

  try-write_ data/io.Data from/int to/int -> int:
    if armed and to - from == 6:
      armed = false
      output_.write data from (from + 2)
      output_.flush
      sleep --ms=50
      return 2
    if chunk-size > 0:
      count := min chunk-size (to - from)
      output_.write data from (from + count)
      output_.flush
      sleep --ms=3
      return count
    return output_.write data from to

// The expect library exits on failure, which skips modem cleanup. Throw instead
// so the caller can reset the modem and release its UART before reporting it.
check condition/bool:
  if not condition: throw "AT2_CHECK_FAILED"

check-equals expected actual:
  if expected != actual:
    throw "AT2_CHECK_FAILED: expected <$expected>, actual <$actual>"

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import uart

/**
EC618 half of the UART2 RS485-half-duplex test (device under test).

Opens UART2 in $uart.Port.MODE-RS485-HALF-DUPLEX with the direction (DE)
  line on PAD33 (= GPIO18, ESP32 IO16 — free because the control-lane tests
  only ever use UART1's TX pad). The driver must raise DE just before each
  transmission and drop it once the last bit has left the shift register;
  the ESP32 helper watches the DE line and verifies exactly one clean pulse
  per message while this side verifies the data round-trip (echo received
  with DE low, i.e. RX works in RS485 mode).

Plan (fixed on both sides, no control lane): for each baud, ITERATIONS
  token round-trips, then one BIG-SIZE message — long enough that a DE drop
  between internal TX chunks would be visible — acknowledged by the helper
  with a single 'K' after it checked the DE pulse.

Wiring: EC618 UART2 TX (PAD26) -> IO27; IO14 -> EC618 UART2 RX (PAD25);
        EC618 PAD33 (DE, plain GPIO) -> IO16.

Run via the mini-jag tester (start uart2-rs485-esp32.toit on the ESP32
  FIRST):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-rs485-ec618.toit
```
*/

BAUDS ::= [9600, 115200, 921600]
ITERATIONS ::= 5
TOKEN-SIZE ::= 256
BIG-SIZE ::= 4096
DE-PAD ::= 33

main:
  failures := []

  BAUDS.do: | baud/int |
    // After the previous phase's ack the helper still sleeps 200ms before
    // reopening its port at the new baud; sending into that window loses
    // the first token (observed: the whole phase then runs shifted by one
    // message).
    if baud != BAUDS.first: sleep --ms=1000
    port := Ec618.uart2
        --baud-rate=baud
        --mode=uart.Port.MODE-RS485-HALF-DUPLEX
        --rs485-de=(Ec618.pad DE-PAD)

    ITERATIONS.repeat: | i/int |
      token := ByteArray TOKEN-SIZE: (it * 31 + 7 + i) & 0xff
      port.out.write token
      got := read-exactly port TOKEN-SIZE
      ok := got == token
      print "uart2-rs485-ec618: $baud iter $i $(ok ? "ok" : "FAIL (echo $got.size bytes)")"
      if not ok: failures.add "$baud/iter$i"

    big := ByteArray BIG-SIZE: (it * 31 + 7) & 0xff
    port.out.write big
    ack := read-exactly port 1
    ack-ok := ack == #['K']
    print "uart2-rs485-ec618: $baud big $(ack-ok ? "ok" : "FAIL (ack $ack)")"
    if not ack-ok: failures.add "$baud/big"

    port.close

  if not failures.is-empty:
    print "uart2-rs485-ec618: FAIL $failures"
    throw "UART2 RS485 test failed: $failures"
  print "uart2-rs485-ec618: PASS $BAUDS.size bauds x ($ITERATIONS round-trips + 1 big)"

// Reads exactly n bytes (or fewer on a 5s stall), as one ByteArray.
read-exactly port/uart.Port n/int -> ByteArray:
  result := #[]
  while result.size < n:
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=5000: port.in.read
    if chunk == null: break
    result += chunk
  return result.size > n ? result[..n] : result

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import gpio.dac show Dac
import uart

import .wiring as wiring

BAUD ::= 115_200
REPLY-TIMEOUT-MS ::= 5_000
SETTLE ::= Duration --ms=30
WEAK-SETTLE ::= Duration --ms=150
ADC-SETTLE ::= Duration --ms=750
ECHO-SIZE ::= 4_096
ADC-LEVELS ::= [0.2, 0.8, 1.6, 2.4, 3.0]

/** Runs the ESP32 side of the RP2350 electrical harness test. */
main args:
  if args.size > 0:
    if args == ["--pulse-run"]:
      pulse-run
      return
    if args == ["--enter-bootsel"]:
      enter-bootsel
      return
    print "Usage: rig-test-esp32.toit [--pulse-run|--enter-bootsel]"
    exit 2

  port := uart.Port
      --rx=wiring.ESP32-UART-RX-PIN
      --tx=wiring.ESP32-UART-TX-PIN
      --baud-rate=BAUD
  failures := 0
  revision := 0
  try:
    revision = test-uart port

    wiring.DIGITAL-WIRES.do: | wire/List |
      rp/int := wire[0]
      esp/int := wire[1]
      if not (test-digital-wire port rp esp): failures++

    if not (test-weak-wire port revision): failures++
    failures += test-adc-wires port
    expect-reply port "RELEASE" "OK RELEASE"
  finally:
    port.close

  if failures != 0:
    print "RIG FAIL $failures signal test(s) failed"
    exit 1
  print "RIG PASS all UART, digital, weak-pull, and ADC signal tests passed"
  print "RUN and BOOT are separate opt-in actions; their result requires host USB observation"

test-uart port/uart.Port -> int:
  banner := receive-until-prefix port "RIG RP2350 REV " 15_000
  banner-parts := banner.split " "
  revision := int.parse banner-parts.last
  print "WIRE GP16 -> ESP34 PASS target banner received"

  token := "c5ff57f7"
  expected-prefix := "READY $token REV "
  // More than one pre-handshake banner may already be buffered. Once HELLO is
  // received the target stops producing them, so skip them to the token reply.
  ready/string? := null
  for attempt := 0; attempt < 5 and not ready; attempt++:
    send-line port "HELLO $token"
    catch:
      ready = receive-until-prefix port expected-prefix 1_500
  if not ready:
    print "WIRE GP1 <- ESP4 FAIL target did not accept HELLO after 5 attempts"
    throw "UART command path failed"
  ready-parts := ready.split " "
  revision = int.parse ready-parts.last
  print "WIRE GP1 <- ESP4 PASS target accepted exact command token"

  send-line port "ECHO $ECHO-SIZE"
  if (read-line port) != "ECHO $ECHO-SIZE": throw "target rejected UART echo"
  payload := ByteArray ECHO-SIZE
  ECHO-SIZE.repeat: | i |
    payload[i] = (i * 73 + (i >> 4) + 19) & 0xff
  echoed := #[]
  offset := 0
  while offset < payload.size:
    end := min (offset + 64) payload.size
    port.out.write payload[offset .. end]
    port.out.flush
    echoed += read-exactly port (end - offset)
    offset = end
  if echoed != payload:
    print "UART0 GP1/GP16 FAIL exact echo got $(echoed.size)/$ECHO-SIZE bytes"
    throw "UART binary echo failed"
  print "UART0 GP1/GP16 PASS exact $(ECHO-SIZE)-byte binary echo"
  return revision

test-digital-wire port/uart.Port rp/int esp/int -> bool:
  pin := gpio.Pin esp --input
  error := catch:
    expect-reply port "OUT $rp 0" "OK OUT $rp 0"
    sleep SETTLE
    low := pin.get
    expect-reply port "OUT $rp 1" "OK OUT $rp 1"
    sleep SETTLE
    high := pin.get
    expect-reply port "IN $rp" "OK IN $rp"
    if low != 0 or high != 1:
      throw "target drive observed low=$low high=$high"
    print "WIRE GP$rp -> ESP$esp PASS low/high"

    pin.configure --output --value=0
    sleep SETTLE
    target-low := read-target-pin port rp
    pin.set 1
    sleep SETTLE
    target-high := read-target-pin port rp
    pin.configure --input
    if target-low != 0 or target-high != 1:
      throw "target read low=$target-low high=$target-high"
    print "WIRE GP$rp <- ESP$esp PASS low/high"
  // Release both ends even when a level check failed.
  pin.configure --input
  catch: expect-reply port "IN $rp" "OK IN $rp"
  pin.close
  if error:
    print "WIRE GP$rp <-> ESP$esp FAIL $error"
    return false
  return true

test-weak-wire port/uart.Port revision/int -> bool:
  stimulus := gpio.Pin wiring.ESP32-WEAK-STIMULUS-PIN --output --value=0
  observer := gpio.Pin wiring.ESP32-WEAK-OBSERVE-PIN --input
  failed := false
  try:
    expect-pull port "N"
    sleep WEAK-SETTLE
    if observer.get != 0 or (read-target-pin port wiring.RP2350-WEAK-PIN) != 0:
      print "WIRE GP33 <-1Mohm- ESP17 FAIL weak-low did not reach target and observer"
      failed = true
    else:
      print "WIRE GP33 <-1Mohm- ESP17 PASS weak-low"

    stimulus.set 1
    sleep WEAK-SETTLE
    if observer.get != 1 or (read-target-pin port wiring.RP2350-WEAK-PIN) != 1:
      print "WIRE GP33 <-1Mohm- ESP17 FAIL weak-high did not reach target and observer"
      failed = true
    else:
      print "WIRE GP33 <-1Mohm- ESP17 PASS weak-high"

    stimulus.set 0
    reply := expect-pull port "U"
    sleep WEAK-SETTLE
    if reply != 1 or observer.get != 1:
      print "GP33 INTERNAL PULL-UP FAIL against ESP17 low through 1Mohm"
      failed = true
    else:
      print "GP33 INTERNAL PULL-UP PASS independently observed on ESP35"

    stimulus.set 1
    reply = expect-pull port "D"
    sleep WEAK-SETTLE
    if reply != 0 or observer.get != 0:
      if revision == 2:
        print "GP33 INTERNAL PULL-DOWN INCONCLUSIVE RP2350 A2 revision 2; result matches E9 leakage erratum"
      else:
        print "GP33 INTERNAL PULL-DOWN FAIL target=$reply observer=$observer.get"
        failed = true
    else:
      print "GP33 INTERNAL PULL-DOWN PASS independently observed on ESP35"

    stimulus.configure --input
    expect-reply port "OUT 33 0" "OK OUT 33 0"
    sleep WEAK-SETTLE
    low := observer.get
    expect-reply port "OUT 33 1" "OK OUT 33 1"
    sleep WEAK-SETTLE
    high := observer.get
    if low != 0 or high != 1:
      print "WIRE GP33 -> ESP35 FAIL observer low=$low high=$high"
      failed = true
    else:
      print "WIRE GP33 -> ESP35 PASS low/high"
  finally:
    stimulus.configure --input
    catch: expect-reply port "IN 33" "OK IN 33"
    observer.close
    stimulus.close
  return not failed

test-adc-wires port/uart.Port -> int:
  dac0 := Dac wiring.ESP32-DAC-PINS[0]
  dac1 := Dac wiring.ESP32-DAC-PINS[1]
  failures := 0
  try:
    dac0.set 0.0
    dac1.set 0.0
    if not (test-adc-wire port wiring.RP2350-ADC-PINS[0] dac0): failures++
    dac0.set 0.0
    if not (test-adc-wire port wiring.RP2350-ADC-PINS[1] dac1): failures++
  finally:
    dac0.set 0.0
    dac1.set 0.0
    dac0.close
    dac1.close
  return failures

test-adc-wire port/uart.Port rp/int dac/Dac -> bool:
  readings := []
  ADC-LEVELS.do: | level/float |
    dac.set level
    sleep ADC-SETTLE
    send-line port "ADC $rp 64"
    line := read-line port
    parts := line.split " "
    if parts.size != 5 or parts[0] != "ADC" or (int.parse parts[1]) != rp:
      throw "malformed ADC reply $parts"
    mean := int.parse parts[2]
    minimum := int.parse parts[3]
    maximum := int.parse parts[4]
    readings.add mean
    print "ADC GP$rp stimulus=$(%.1f level)V raw=$mean range=$minimum..$maximum"
  ok := readings.last - readings.first >= 2_500
  for i := 1; i < readings.size; i++:
    if readings[i] - readings[i - 1] < 300: ok = false
  esp := rp == 40 ? wiring.ESP32-DAC-PINS[0] : wiring.ESP32-DAC-PINS[1]
  print "WIRE GP$rp <- ESP$esp DAC $(ok ? "PASS" : "FAIL") staircase=$readings"
  return ok

expect-pull port/uart.Port mode/string -> int:
  send-line port "PULL 33 $mode"
  line := read-line port
  parts := line.split " "
  if parts.size != 4 or parts[0] != "PULL" or parts[1] != "33" or parts[2] != mode:
    throw "malformed pull reply $parts"
  return int.parse parts[3]

read-target-pin port/uart.Port pin/int -> int:
  send-line port "READ $pin"
  line := read-line port
  parts := line.split " "
  if parts.size != 3 or parts[0] != "VALUE" or (int.parse parts[1]) != pin:
    throw "malformed GPIO reply $parts"
  return int.parse parts[2]

expect-reply port/uart.Port command/string expected/string -> none:
  send-line port command
  actual := read-line port
  if actual != expected: throw "'$command' expected '$expected', got '$actual'"

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

read-line port/uart.Port -> string:
  return with-timeout --ms=REPLY-TIMEOUT-MS:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]

receive-until-prefix port/uart.Port prefix/string timeout-ms/int -> string:
  return with-timeout --ms=timeout-ms:
    while true:
      line := read-line port
      if line.starts-with prefix: return line

read-exactly port/uart.Port size/int -> ByteArray:
  return with-timeout --ms=REPLY-TIMEOUT-MS:
    result := #[]
    while result.size < size:
      chunk := port.in.read
      if not chunk: throw "UART closed after $result.size/$size bytes"
      result += chunk
    if result.size != size: throw "UART returned $(result.size), expected $size"
    result

pulse-run -> none:
  run := gpio.Pin wiring.ESP32-RUN-PIN --output --open-drain --value=1
  try:
    sleep --ms=100
    run.set 0
    sleep --ms=150
    run.set 1
    print "RUN ACTION complete; verify target USB disconnected and returned"
  finally:
    run.set 1
    run.close

enter-bootsel -> none:
  run := gpio.Pin wiring.ESP32-RUN-PIN --output --open-drain --value=1
  boot := gpio.Pin wiring.ESP32-BOOT-PIN --output --open-drain --value=1
  try:
    // BOOT must be asserted before RUN on this rig.
    boot.set 0
    sleep --ms=100
    run.set 0
    sleep --ms=150
    run.set 1
    sleep --ms=1_000
    boot.set 1
    print "BOOT/RUN ACTION complete; verify USB 2e8a:000f before flashing"
  finally:
    run.set 1
    boot.set 1
    boot.close
    run.close

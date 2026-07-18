// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Level-1 UART contract tests for EC618.
//
// These tests verify the API contract — what each call promises, what
// errors it should produce — without observing any wires. They run on the
// EC618 itself; no external hardware is required.
//
// The test adapts to whichever firmware variant carries the print
// redirect (UART0/1/2) — or to a build where the redirect was disabled
// entirely. In the disabled case Toit's `print` goes nowhere, so the
// program buffers its output and writes it to UART2 at the end. To
// observe results for that variant, attach a UART reader to UART2's TX
// (mapping 0: PAD26 / GPIO11) at 115200 baud.
//
// Each `expect-throws` / `expect-equals` is a separate assertion. The
// program prints "ALL TESTS PASSED" on success or "FAIL: <case>" with
// the first failure and exits 1.

import ec618
import ec618 show Ec618
import gpio show Pin
import uart

// PAD constants used in negative tests.
PAD-UART2-TX ::= 26
PAD-UART2-RX ::= 25
PAD-NOT-A-GPIO ::= 1     // Pad 1 isn't a GPIO bit in our table.
PAD-OUT-OF-RANGE ::= 99  // Beyond kMaxPadIndex.

// Buffered output for the print-disabled variant. When the print
// redirect is on, $emit calls $print directly; when it's off, $emit
// appends here and $flush-output dumps the buffer to UART2 at the end.
buffered-output_/List := []
print-uart-id_/int := -1

failures := 0

main:
  print-uart-id_ = ec618.print-uart-id
  emit "ec618 print-uart-id = $print-uart-id_"
  try:
    run-tests
    if failures == 0:
      emit "ALL TESTS PASSED"
    else:
      emit "$failures FAILURES"
  finally:
    flush-output
  if failures != 0: exit 1

run-tests -> none:
  test "uart2-default-opens-cleanly":
    port := Ec618.uart2 --baud-rate=115200
    port.close

  test "uart2-mapping-1-opens":
    port := Ec618.uart2 --mapping=1 --baud-rate=115200
    port.close

  test "uart2-tx-only-opens":
    port := Ec618.uart2 --no-tx-disabled --rx-disabled --baud-rate=115200
    port.close

  test "uart2-rx-only-opens":
    port := Ec618.uart2 --tx-disabled --no-rx-disabled --baud-rate=115200
    port.close

  test "uart2-both-disabled-rejected":
    expect-throws "INVALID_ARGUMENT":
      Ec618.uart2 --tx-disabled --rx-disabled --baud-rate=115200

  test "uart2-bad-mapping-rejected":
    expect-throws "INVALID_ARGUMENT":
      Ec618.uart2 --mapping=99 --baud-rate=115200

  test "uart2-flow-control-rejected":
    // UART2 has no hardware flow control; passing CTS/RTS as raw pads
    // through `uart.Port` should fail at the primitive layer.
    expect-throws "INVALID_ARGUMENT":
      uart.Port
          --tx=(Pin PAD-UART2-TX)
          --rx=(Pin PAD-UART2-RX)
          --cts=(Pin 32)  // UART1 CTS pad — not valid for UART2.
          --baud-rate=115200

  // Adapts to whichever UART carries print in this build (or skips if
  // the redirect is disabled entirely).
  if print-uart-id_ == 0:
    test "uart0-collides-with-print":
      expect-throws "ALREADY_IN_USE":
        Ec618.uart0 --baud-rate=115200
  else if print-uart-id_ == 1:
    test "uart1-collides-with-print":
      expect-throws "ALREADY_IN_USE":
        Ec618.uart1 --baud-rate=115200
  else if print-uart-id_ == 2:
    test "uart2-collides-with-print":
      expect-throws "ALREADY_IN_USE":
        Ec618.uart2 --baud-rate=115200
  else:
    // CONFIG_TOIT_EC618_PRINT_UART=0: every UART must open without
    // ALREADY_IN_USE (modulo other ownership rules).
    test "uart0-available-when-print-disabled":
      port := Ec618.uart0 --baud-rate=115200
      port.close
    test "uart1-available-when-print-disabled":
      port := Ec618.uart1 --baud-rate=115200
      port.close

  // Flow-control mapping tests for UART0. Skipped when UART0 carries
  // the print redirect — the collision check above already covers that
  // case and any further open of UART0 would just bounce on
  // ALREADY_IN_USE.
  if print-uart-id_ != 0:
    test "uart0-rts-but-no-cts-ok":
      // Mapping 0 of UART0 has both RTS and CTS pads available; enabling
      // only one is allowed (it just wires up that one direction).
      port := Ec618.uart0 --rts-enabled --baud-rate=115200
      port.close

    test "uart0-alt-mapping-no-flow-control":
      // Mapping 1 of UART0 has no flow control pads; rts-enabled must fail.
      expect-throws "INVALID_ARGUMENT":
        Ec618.uart0 --mapping=1 --rts-enabled --baud-rate=115200

  // The same mapping checks for UART1. UART1 mapping 0 has both
  // RTS and CTS pads; mapping 1 has only a CTS pad, so requesting RTS
  // on that mapping must be rejected.
  if print-uart-id_ != 1:
    test "uart1-rts-but-no-cts-ok":
      port := Ec618.uart1 --rts-enabled --baud-rate=115200
      port.close

    test "uart1-alt-mapping-no-flow-control":
      expect-throws "INVALID_ARGUMENT":
        Ec618.uart1 --mapping=1 --rts-enabled --baud-rate=115200

  test "uart-bad-pin-pair-rejected":
    // Two random pads that aren't a UART pair.
    expect-throws "INVALID_ARGUMENT":
      uart.Port --tx=(Pin 13) --rx=(Pin 14) --baud-rate=115200

  test "uart-no-tx-no-rx-rejected":
    expect-throws "INVALID_ARGUMENT":
      uart.Port --tx=null --rx=null --baud-rate=115200

  test "uart-invert-tx-rejected":
    expect-throws "INVALID_ARGUMENT":
      uart.Port
          --tx=(Pin PAD-UART2-TX)
          --rx=(Pin PAD-UART2-RX)
          --baud-rate=115200
          --invert-tx

  test "uart-mode-irda-rejected":
    expect-throws "INVALID_ARGUMENT":
      uart.Port
          --tx=(Pin PAD-UART2-TX)
          --rx=(Pin PAD-UART2-RX)
          --baud-rate=115200
          --mode=uart.Port.MODE-IRDA

  test "uart-baud-zero-rejected":
    expect-throws "INVALID_ARGUMENT":
      Ec618.uart2 --baud-rate=0

  test "uart-baud-too-high-rejected":
    expect-throws "INVALID_ARGUMENT":
      Ec618.uart2 --baud-rate=8_000_000

  test "uart2-double-open-rejected":
    port := Ec618.uart2 --baud-rate=115200
    try:
      expect-throws "ALREADY_IN_USE":
        Ec618.uart2 --baud-rate=115200
    finally:
      port.close

  test "uart2-reopen-after-close":
    p1 := Ec618.uart2 --baud-rate=115200
    p1.close
    p2 := Ec618.uart2 --baud-rate=9600
    p2.close

  test "ec618-gpio-primary-pads":
    expected := [
      15, 16, 17, 18, 19, 20, 21, 22,
      23, 24, 25, 26, 27, 28, 29, 30,
      31, 32, 33, 34, 40, 41, 42, 43,
      44, 45, 46, 47, 48, 35, 36, 37,
    ]
    expected.size.repeat: | gpio/int |
      pad := expected[gpio]
      // UART2's rescue listener and the selected print UART own their pads in
      // the mini-jag envelope. Those mappings are covered by the table/build
      // checks; exercise every unoccupied primary pad here.
      occupied-pad := pad == 25 or pad == 26 or (print-uart-id_ == 0 and (pad == 29 or pad == 30)) or (print-uart-id_ == 1 and (pad == 33 or pad == 34))
      if not occupied-pad:
        p := Ec618.gpio gpio
        try:
          if p.num != pad: throw "GPIO$gpio: expected PAD$pad, got PAD$(p.num)"
        finally:
          p.close

  test "ec618-gpio-alt-pads":
    // GPIO12..15 and GPIO18..19 have distinct ALT4 physical pads.
    mappings := [[12, 11], [13, 12], [14, 13], [15, 14], [18, 38], [19, 39]]
    mappings.do: | mapping/List |
      gpio := mapping[0]
      pad := mapping[1]
      p := Ec618.gpio gpio --alt
      try:
        if p.num != pad: throw "GPIO$gpio alt: expected PAD$pad, got PAD$(p.num)"
      finally:
        p.close

  test "ec618-gpio-no-alt-rejected":
    // GPIO11 has no alt pad; --alt must fail.
    expect-throws "INVALID_ARGUMENT":
      Ec618.gpio 11 --alt

  test "ec618-gpio-shared-bit-exclusive":
    // GPIO12's PAD27 and PAD11 are distinct physical resources, but share
    // direction/data/interrupt registers. They cannot be active as GPIO at
    // the same time.
    primary := Ec618.gpio 12
    try:
      primary.configure --output --value=0
      expect-throws "ALREADY_IN_USE":
        alternate := Ec618.gpio 12 --alt
        alternate.configure --output --value=0
    finally:
      primary.close

    // Closing one PAD releases the shared controller for the other PAD.
    alternate := Ec618.gpio 12 --alt
    alternate.configure --output --value=0
    alternate.close

  test "ec618-gpio-zero":
    p := Ec618.gpio 0
    p.close

  test "ec618-pad-out-of-range-rejected":
    // Constructing a Pin for an unknown pad fails when the resource is
    // actually used (the GPIO primitive validates on `use`, not on the
    // Toit-side constructor).
    expect-throws:
      p := Ec618.pad PAD-OUT-OF-RANGE
      // Force the primitive to validate.
      p.configure --output

test name/string [block] -> none:
  caught := catch: block.call
  if caught != null:
    emit "FAIL: $name -> $caught"
    failures++
  else:
    emit "ok: $name"

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null:
    throw "expected '$expected' to be thrown, nothing was"
  if caught is string and caught.contains expected:
    return
  throw "expected '$expected', got: $caught"

expect-throws [block] -> none:
  caught := catch: block.call
  if caught == null: throw "expected exception, nothing was thrown"

emit line/string -> none:
  if print-uart-id_ >= 0:
    print line
  else:
    buffered-output_.add line

// Writes the buffered output to UART2 when the print redirect is off.
// A no-op when print is enabled — the lines went straight out via $print.
flush-output -> none:
  if print-uart-id_ >= 0: return
  port := Ec618.uart2 --baud-rate=115200
  try:
    buffered-output_.do: | line/string |
      port.out.write "$line\n"
    port.out.flush
    // Give the UART a moment to drain before the device potentially
    // enters deep sleep — flush returns when the bytes have been handed
    // to the controller, not when they've left the wire.
    sleep --ms=200
  finally:
    port.close

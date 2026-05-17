// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Level-1 UART contract tests for EC618.
//
// These tests verify the API contract — what each call promises, what
// errors it should produce — without observing any wires. They run on the
// EC618 itself; no external hardware is required.
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

failures := 0

main:
  print-uart-id := ec618.print-uart-id
  print "ec618 print-uart-id = $print-uart-id"
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
  if print-uart-id == 0:
    test "uart0-collides-with-print":
      expect-throws "ALREADY_IN_USE":
        Ec618.uart0 --baud-rate=115200
  else if print-uart-id == 1:
    test "uart1-collides-with-print":
      expect-throws "ALREADY_IN_USE":
        Ec618.uart1 --baud-rate=115200
  else if print-uart-id == 2:
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

  test "uart0-rts-but-no-cts-ok":
    // Mapping 0 of UART0 has both RTS and CTS pads available; enabling
    // only one is allowed (it just wires up that one direction).
    port := Ec618.uart0 --rts-enabled --baud-rate=115200
    port.close

  test "uart0-alt-mapping-no-flow-control":
    // Mapping 1 of UART0 has no flow control pads; rts-enabled must fail.
    expect-throws "INVALID_ARGUMENT":
      Ec618.uart0 --mapping=1 --rts-enabled --baud-rate=115200

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
    expect-throws "ALREADY_IN_USE":
      Ec618.uart2 --baud-rate=115200
    port.close

  test "uart2-reopen-after-close":
    p1 := Ec618.uart2 --baud-rate=115200
    p1.close
    p2 := Ec618.uart2 --baud-rate=9600
    p2.close

  test "ec618-gpio-primary":
    // GPIO11 primary pad is PAD26; address resolution should match.
    p := Ec618.gpio 11
    // Just construct/destruct; we'd need a primitive read to assert the
    // pad number, which we don't expose. The fact that no exception
    // fires is the contract.
    p.close

  test "ec618-gpio-alt":
    // GPIO11 alt pad is PAD22.
    p := Ec618.gpio 11 --alt
    p.close

  test "ec618-gpio-no-alt-rejected":
    // GPIO12 has no alt pad; --alt must fail.
    expect-throws "INVALID_ARGUMENT":
      Ec618.gpio 12 --alt

  test "ec618-gpio-undocumented-rejected":
    // GPIO0 is not in our table (yet).
    expect-throws "INVALID_ARGUMENT":
      Ec618.gpio 0

  test "ec618-pad-out-of-range-rejected":
    // Constructing a Pin for an unknown pad fails when the resource is
    // actually used (the GPIO primitive validates on `use`, not on the
    // Toit-side constructor).
    expect-throws:
      p := Ec618.pad PAD-OUT-OF-RANGE
      // Force the primitive to validate.
      p.configure --output

  if failures == 0:
    print "ALL TESTS PASSED"
  else:
    print "$failures FAILURES"
    exit 1

test name/string [block] -> none:
  caught := catch: block.call
  if caught != null:
    print "FAIL: $name -> $caught"
    failures++
  else:
    print "ok: $name"

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

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import system
import .ble-hardware.adapter-policy as policy
import .ble-fixture as fixture

ADDRESS ::= #[6, 5, 4, 3, 2, 1]

main:
  with-timeout --ms=5000:
    [false, true].do: | powered/bool |
      ["state", "power-on", "power-off"].do: | mode/string |
        state := State "normal" powered
        desired := mode == "state" ? powered : mode == "power-on"
        expect-equals desired (configure state mode)
        expect-equals (mode == "state" or powered == desired ? 0 : 1) state.writes
        expect-equals 1 state.radios.size
        expect state.radios[0].closed
    ["busy", "ignored"].do: | fault/string |
      state := State fault false
      expect (configure state "power-on")
      expect-equals 2 state.writes
      expect-equals 2 state.radios.size
      expect (state.radios[0].closed and state.radios[1].closed)
    ["identity-before", "identity-after", "identity-retry"].do: | fault/string |
      state := State fault false
      expect-throw "MGMT_WRONG_ADAPTER": configure state "power-on"
      expect-equals (fault == "identity-before" ? 0 : 1) state.writes
      expect-equals (fault == "identity-retry" ? 2 : 1) state.radios.size
      state.radios.do: expect it.closed
    state := State "query-fail" false
    expect-throw "MGMT_STATUS_10": configure state "state"
    expect-equals 1 state.radios.size
    expect state.radios[0].closed
    state = State "query-fail" false
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=20: configure state "power-on"
    expect-equals 1 state.radios.size
    expect state.radios[0].closed
    state = State "normal" false
    expected := ADDRESS.copy
    expect (policy.configure 7 expected "power-on":
      expected.fill 0
      system.process-stats --gc
      state.open)
    expect-equals (ByteArray 6) expected
    expect-throw "INVALID_ARGUMENT": policy.configure -1 ADDRESS "state": unreachable
    expect-throw "INVALID_ARGUMENT": policy.configure 7 #[] "state": unreachable
    expect-throw "INVALID_ARGUMENT": policy.configure 7 ADDRESS "other": unreachable

configure state/State mode/string -> bool:
  return policy.configure 7 ADDRESS mode: state.open

class State:
  fault/string
  powered/bool := ?
  writes/int := 0
  radios/List := []

  constructor .fault .powered:

  open -> Radio:
    if not radios.is-empty: expect radios.last.closed
    radio := Radio this
    radios.add radio
    return radio

class Radio extends fixture.FakeTransport:
  state_/State
  reads_/int := 0

  constructor .state_:

  send packet/ByteArray -> none:
    expect (not closed)
    expect-equals 7 (io.LITTLE-ENDIAN.uint16 packet 2)
    opcode := io.LITTLE-ENDIAN.uint16 packet 0
    if opcode == 4:
      expect-equals #[4, 0, 7, 0, 0, 0] packet
      reads_++
      if state_.fault == "query-fail":
        reply_ opcode #[] --status=10
        return
      info := ByteArray 280
      wrong := state_.fault == "identity-before" or
          (state_.fault == "identity-after" and reads_ == 2) or
          (state_.fault == "identity-retry" and state_.radios.size == 2)
      info.replace 0 (wrong ? (ByteArray 6) : ADDRESS.reverse)
      io.LITTLE-ENDIAN.put-uint32 info 13 (state_.powered ? 1 : 0)
      reply_ opcode info
    else:
      expect-equals 5 opcode
      expect-equals 7 packet.size
      expect-equals #[5, 0, 7, 0, 1, 0] packet[..6]
      expect (packet[6] == 0 or packet[6] == 1)
      state_.writes++
      if state_.writes == 1 and ["busy", "identity-retry"].contains state_.fault:
        reply_ opcode #[] --status=10
        return
      if state_.fault != "ignored" or state_.writes != 1:
        state_.powered = packet[6] == 1
      // An acknowledgement alone is insufficient: 'ignored' lies about state.
      reply_ opcode #[packet[6], 0, 0, 0]

  reply_ opcode/int payload/ByteArray --status/int=0:
    response := ByteArray (9 + payload.size)
    io.LITTLE-ENDIAN.put-uint16 response 0 1
    io.LITTLE-ENDIAN.put-uint16 response 2 7
    io.LITTLE-ENDIAN.put-uint16 response 4 (payload.size + 3)
    io.LITTLE-ENDIAN.put-uint16 response 6 opcode
    response[8] = status
    response.replace 9 payload
    received.add response

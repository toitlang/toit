// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-pairing as smp
import expect show *
import system
import .ble-smp-pairing-test as fixture

main:
  [false, true].do: | numeric/bool |
    // Request, response, both public keys, confirm, both randoms and both checks.
    9.repeat: | step/int |
      reference := Replay step --numeric=numeric
      size := reference.packet.size
      reference.close
      size.repeat: | length/int |
        replay := Replay step --numeric=numeric
        reject replay replay.packet[..length].copy
      replay := Replay step --numeric=numeric
      reject replay (replay.packet + #[0])
      // Unknown commands must neither advance pairing nor refresh its timer.
      replay = Replay step --numeric=numeric
      state := replay.target.state
      deadline := replay.target.deadline
      256.repeat: | opcode/int |
        if opcode != 0 and opcode != 0x0a and opcode <= 0x0e: continue.repeat
        expect-equals [] (replay.target.receive #[opcode, 0, 0] --now=10)
        expect-equals state replay.target.state
        expect-equals deadline replay.target.deadline
        expect (not replay.target.verified)
        expect-throw "SMP_KEY_NOT_READY": replay.target.key
      replay.close
    // Each bit of either peer's DHKey Check is authenticated before key release.
    [7, 8].do: | step/int |
      16.repeat: | offset/int |
        8.repeat: | bit/int |
          replay := Replay step --numeric=numeric
          changed := replay.packet.copy
          changed[offset + 1] ^= 1 << bit
          reject replay changed --reason=0x0b
    // Valid replays still complete after the malformed-input campaign.
    replay := Replay 8 --numeric=numeric
    expect-equals [] (replay.target.receive replay.packet --now=10)
    expect (replay.pair.a.verified and replay.pair.b.verified)
    expect-equals numeric replay.pair.a.authenticated
    expect-equals numeric replay.pair.b.authenticated
    expect-equals replay.pair.a.key replay.pair.b.key
    replay.close

reject replay/Replay packet/ByteArray --reason/int=0x0a:
  original := packet.copy
  expect-equals [#[5, reason]] (replay.target.receive packet --now=10)
  expect-equals original packet
  packet.fill 0
  system.process-stats --gc
  expect-equals "failed" replay.target.state
  expect-equals null replay.target.deadline
  expect-equals reason replay.target.failure
  expect (not replay.target.verified and not replay.target.authenticated)
  expect (not replay.target.bonding)
  expect-throw "SMP_KEY_NOT_READY": replay.target.key
  expect-throw "SMP_KEY_NOT_READY": replay.target.distribute-identity
  expect-throw "SMP_KEY_NOT_READY": replay.target.receive-identity
  expect-throw "SMP_INVALID_STATE": replay.target.receive replay.packet --now=11
  expect-throw "SMP_INVALID_STATE": replay.target.approve true --now=11
  replay.close

// Rebuilds a valid live exchange up to one incoming PDU. Cryptographic nonces
// remain fresh; the receive order and mutations are deterministic.
class Replay:
  pair/fixture.Pair
  target/smp.Session := ?
  packet/ByteArray := ?

  constructor step/int --numeric/bool:
    pair = fixture.Pair --numeric=numeric --bond
    target = pair.b
    pending/List := pair.a.start --now=0
    step.repeat:
      outgoing := target.receive (pending.remove --at=0) --now=0
      if not outgoing.is-empty:
        expect pending.is-empty
        pending = outgoing
        target = target == pair.a ? pair.b : pair.a
      if pending.is-empty:
        expect numeric
        expect-equals [] (pair.b.approve true --now=0)
        pending = pair.a.approve true --now=0
        target = pair.b
    packet = pending[0]

  close -> none:
    pair.a.close
    pair.b.close

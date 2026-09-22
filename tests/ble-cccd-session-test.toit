// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.attribute-server as attributes
import ble.experimental.cccd-store as cccd
import ble.experimental.security-state show SecurityState

main:
  with-timeout --ms=15_000:
    roundtrip
    malformed
    transaction false false
    transaction true false
    transaction false true
    transaction false false --close
    canceled-save
    deadline false
    deadline true
    service-changed

class Evidence implements SecurityState:
  paired/bool := true
  encrypted/bool := true
  authenticated/bool := true

class Store implements cccd.Store:
  state/ByteArray? := null
  saves/int := 0
  fail/bool := false
  pause/bool := false
  pause-load/bool := false
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  load -> ByteArray?:
    if pause-load: release.get
    return state and state.copy
  save bytes/ByteArray -> none:
    if pause:
      entered.set true
      release.get
    saves++
    state = bytes.copy
    // Deliberately model a failure after a store may have committed.
    if fail: throw "STORE_FAILED"
    bytes.fill 0

database -> attributes.Database:
  result := attributes.Database
  result.add-service #[0xf0, 0xff]
  expect-equals 3 (result.add-characteristic #[0xf1, 0xff] --read --notify --value=#[42])
  expect-equals 6 (result.add-characteristic #[0xf2, 0xff] --read --indicate --authenticated --value=#[43])
  expect-equals 9 (result.add-characteristic #[0xf3, 0xff] --read --write --authenticated --value=#[7])
  return result

roundtrip:
  layout := database
  store := Store
  evidence := Evidence
  expect-throw "GATT_CCCD_SECURITY_REQUIRED": layout.session --cccd-store=store
  first := layout.session --security=evidence --cccd-store=store
  try:
    expect-equals #[0x13] (first.request #[0x12, 4, 0, 1, 0])
    expect-equals #[0x13] (first.request #[0x12, 7, 0, 2, 0])
    expect-equals #[1, 2, 4, 0, 1, 0, 7, 0, 2, 0] store.state
    expect-equals 2 store.saves
    expect-equals #[1, 0x12, 4, 0, 0x13] (first.request #[0x12, 4, 0, 2, 0])
    expect-equals 2 store.saves
    system.process-stats --gc
  finally:
    first.close
  evidence.encrypted = false
  second := layout.session --security=evidence --cccd-store=store
  try:
    expect (not (second.subscribed 3))
    expect-null (second.notification 3)
    expect-equals #[1, 0x0a, 4, 0, 0x0f] (second.request #[0x0a, 4, 0])
    evidence.encrypted = true
    store.state.fill 0
    expect-equals #[0x0b, 1, 0] (second.request #[0x0a, 4, 0])
    expect-equals #[0x1b, 3, 0, 42] (second.notification 3)
    expect-equals #[0x1d, 6, 0, 43] (second.indication 6)
    expect-equals #[0x13] (second.request #[0x12, 4, 0, 0, 0])
    expect-equals #[1, 1, 7, 0, 2, 0] store.state
    expect-equals #[0x13] (second.request #[0x12, 7, 0, 0, 0])
    expect-equals #[1, 0] store.state
  finally:
    second.close
  // A distinct store and an ordinary unbonded session never inherit state.
  other := layout.session --security=evidence --cccd-store=Store
  plain := layout.session
  try:
    expect (not (other.subscribed 3))
    expect-equals #[0x0b, 0, 0] (plain.request #[0x0a, 4, 0])
  finally:
    other.close
    plain.close

malformed:
  [
    #[], #[1], #[2, 0], #[1, 65], #[1, 1],
    #[1, 1, 3, 0, 1, 0], #[1, 1, 64, 0, 1, 0],
    #[1, 1, 4, 0, 0, 0], #[1, 1, 4, 0, 2, 0], #[1, 1, 4, 0, 1, 1],
    #[1, 2, 4, 0, 1, 0, 4, 0, 1, 0],
    #[1, 2, 7, 0, 2, 0, 4, 0, 1, 0], ByteArray 259,
  ].do: | state/ByteArray |
    layout := database
    store := Store
    store.state = state
    expect-throw "GATT_INVALID_CCCD_STATE": layout.session --security=Evidence --cccd-store=store
    // Rejection did not seal or partially publish the database.
    expect-equals 10 (layout.add-service #[0xf4, 0xff])

transaction fail/bool downgrade/bool --close/bool=false:
  layout := database
  store := Store
  store.pause = true
  store.fail = fail
  evidence := Evidence
  session := layout.session --security=evidence --cccd-store=store
  response/ByteArray? := null
  error/any := null
  ended := monitor.Latch
  worker/Task? := null
  try:
    expect-equals #[0x17, 4, 0, 0, 0, 1, 0] (session.request #[0x16, 4, 0, 0, 0, 1, 0])
    expect-equals #[0x19] (session.request #[0x18, 0])
    expect-equals 0 store.saves
    expect (not (session.subscribed 3))
    [#[0x16, 4, 0, 0, 0, 1, 0], #[0x16, 7, 0, 0, 0, 2, 0], #[0x16, 9, 0, 0, 0, 99]].do: | packet/ByteArray |
      expected := packet.copy
      expected[0] = 0x17
      expect-equals expected (session.request packet)
    expect-equals 0 store.saves
    worker = task::
      try:
        error = catch: response = session.request #[0x18, 1]
      finally:
        critical-do --no-respect-deadline: ended.set true
    store.entered.get
    expect-null response
    expect (not (session.subscribed 3))
    expect-equals #[7] (layout.value 9)
    expect-throw "GATT_REQUEST_BUSY": session.request #[0x0a, 3, 0]
    session.writes-do: | _ _ | unreachable
    if downgrade: evidence.authenticated = false
    if close: session.close
    store.release.set true
    ended.get
    expect-equals 1 store.saves
    expect-equals #[1, 2, 4, 0, 1, 0, 7, 0, 2, 0] store.state
    if fail or downgrade or close:
      expect-equals (fail ? "STORE_FAILED" : close ? "ATT_SERVER_CLOSED" : "GATT_INSUFFICIENT_SECURITY") error
      expect-null response
      expect-equals #[7] (layout.value 9)
      expect-throw "ATT_SERVER_CLOSED": session.request #[0x0a, 3, 0]
      session.writes-do: | _ _ | unreachable
    else:
      expect-null error
      expect-equals #[0x19] response
      expect (session.subscribed 3)
      expect-equals #[99] (layout.value 9)
      count := 0
      session.writes-do: | _ _ | count++
      expect-equals 3 count
  finally:
    store.release.set true
    if worker: worker.cancel
    session.close

deadline loading/bool:
  layout := database
  store := Store
  store.pause-load = loading
  store.pause = not loading
  session/attributes.Session? := null
  started := Time.monotonic-us
  try:
    error := catch:
      session = layout.session --security=Evidence --cccd-store=store
      if loading: unreachable
      session.request #[0x12, 4, 0, 1, 0]
    expect-equals DEADLINE-EXCEEDED-ERROR error
    expect (2_500_000 <= Time.monotonic-us - started < 5_000_000)
    expect-equals 0 store.saves
    if session:
      expect-throw "ATT_SERVER_CLOSED": session.request #[0x0a, 3, 0]
    else:
      expect-equals 10 (layout.add-service #[0xf4, 0xff])
  finally:
    store.release.set true
    if session: session.close

canceled-save:
  store := Store
  store.pause = true
  session := database.session --security=Evidence --cccd-store=store
  ended := monitor.Latch
  worker := task::
    try:
      session.request #[0x12, 4, 0, 1, 0]
      unreachable
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    store.entered.get
    worker.cancel
    ended.get
    expect-equals 0 store.saves
    expect-throw "ATT_SERVER_CLOSED": session.request #[0x0a, 3, 0]
  finally:
    store.release.set true
    worker.cancel
    session.close

service-changed:
  layout := attributes.Database.with-defaults
  store := Store
  evidence := Evidence
  first := layout.session --security=evidence --cccd-store=store
  try:
    expect-equals #[0x13] (first.request #[0x12, 9, 0, 2, 0])
    first.writes-do: | _ _ | unreachable
  finally:
    first.close
  second := layout.session --security=evidence --cccd-store=store
  try:
    expect-equals #[0x1d, 8, 0, 1, 0, 0xff, 0xff] (second.indication 8)
  finally:
    second.close

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.service.shared-host as shared
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-multilink-test as links
import .ble-peripheral-test as peripheral
import .ble-service-multiclient-test as clients

main:
  with-timeout --ms=10_000:
    unused
    mixed false
    mixed true
    waiting-cancel
    factory-failure
    close-failure
    close-failure --failed-first
    close-failure --join-error
    close-failure --no-close-error --join-error
    factory-close-failure
    automatic-close-failure

automatic-close-failure:
  factory := Factory
  pool := shared.Host factory
  pool.retain
  pool.retain
  responder := task:: fixture.initialize-replies factory.radio
  try:
    pool.setup: | owner/central.Central info/hci.Capabilities |
      expect owner == factory.host
    factory.radio.throw-close = true
    // Automatic teardown preserves this primary error while retaining the
    // separate close failure. Neither of the two reservations released yet.
    factory.radio.received.fail "RADIO_FAILED"
    expect-throw "RADIO_FAILED": factory.host.receive
    factory.host.wait-closed
    pool.release
    expect (not pool.released)
    // Do not admit a third owner between first and final release, or invoke
    // an existing owner's setup block with the failed controller.
    expect-throw "GATT_SERVICE_BUSY": pool.retain
    expect-throw "GATT_SHARED_HOST_FAILED": pool.setup: unreachable
    expect-throw "TRANSPORT_CLOSE_FAILED": pool.release
    expect (not pool.released)
    expect-equals 1 factory.radio.closes
    expect-equals 1 factory.opens
  finally:
    responder.cancel
    pool.fail
    factory.host.wait-closed

class Radio extends fixture.FakeTransport:
  closes/int := 0
  throw-close/bool := false
  close -> none:
    closes++
    if throw-close: throw "TRANSPORT_CLOSE_FAILED"
    super

class Factory implements shared.Factory:
  radio/Radio ::= Radio
  opens/int := 0
  creates/int := 0
  roles/List ::= []
  reject/bool := false
  host/Host? := null

  controller-ready radio info -> none:

  open-transport -> Radio:
    opens++
    return radio

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    creates++
    expect-equals 517 receive-limit
    if reject: throw "FIXTURE_HOST_REJECTED"
    host = Host controller info receive-limit roles
    return host

class Host extends central.Central:
  roles_/List
  joins/int := 0
  throw-join/bool := false
  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .roles_:
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit
        --link-limit=2

  on-connected link/central.Link -> none:
    roles_.add link.info.role

  wait-closed -> none:
    joins++
    if throw-join: throw "JOIN_FAILED"
    super

close-failure --failed-first/bool=false --close-error/bool=true --join-error/bool=false:
  factory := Factory
  pool := shared.Host factory
  pool.retain
  responder := task:: fixture.initialize-replies factory.radio
  try:
    pool.setup: | owner/central.Central info/hci.Capabilities |
      expect owner == factory.host
    factory.radio.throw-close = close-error
    factory.host.throw-join = join-error
    if failed-first: pool.fail
    expect-throw (close-error ? "TRANSPORT_CLOSE_FAILED" : "JOIN_FAILED"): pool.release
    expect-equals 1 factory.host.joins
    expect-equals 1 factory.radio.closes
    expect (not pool.released)
    expect-throw "GATT_SERVICE_BUSY": pool.retain
    expect-throw (failed-first ? "GATT_SHARED_HOST_FAILED" : "GATT_SERVICE_BUSY"):
      pool.setup: unreachable
    expect-throw "GATT_SHARED_HOST_NOT_RETAINED": pool.release
  finally:
    responder.cancel
    factory.radio.received.fail "TEST_ENDED"
    pool.fail
    if factory.host:
      factory.host.throw-join = false
      factory.host.wait-closed

factory-close-failure:
  factory := Factory
  factory.reject = true
  factory.radio.throw-close = true
  pool := shared.Host factory
  pool.retain
  responder := task:: fixture.initialize-replies factory.radio
  try:
    // Setup keeps the factory error; release reports the retained close error
    // even though the controller's subsequent close is an idempotent no-op.
    expect-throw "FIXTURE_HOST_REJECTED": pool.setup: unreachable
    expect-throw "TRANSPORT_CLOSE_FAILED": pool.release
    expect (not pool.released)
    expect-equals 1 factory.radio.closes
    expect-throw "GATT_SERVICE_BUSY": pool.retain
    expect-throw "FIXTURE_HOST_REJECTED": pool.setup: unreachable
  finally:
    responder.cancel
    factory.radio.received.fail "TEST_ENDED"
    pool.fail

unused:
  factory := Factory
  pool := shared.Host factory
  expect-throw "GATT_SHARED_HOST_NOT_RETAINED": pool.release
  expect-throw "GATT_SERVICE_BUSY": pool.setup: unreachable
  pool.retain
  pool.release
  expect pool.released
  expect-equals 0 factory.opens
  expect-throw "GATT_SERVICE_BUSY": pool.retain
  expect-throw "GATT_SERVICE_BUSY": pool.setup: unreachable
  expect-throw "GATT_SHARED_HOST_NOT_RETAINED": pool.release

accept radio/Radio peer/int handle/int:
  peripheral.setup radio
  event := links.connected peer handle
  event[7] = 1
  radio.received.add event
  peripheral.reply radio 0x200a #[0]

mixed peripheral-first/bool:
  factory := Factory
  pool := shared.Host factory
  pool.retain
  pool.retain
  host/central.Central? := null
  first/central.Link? := null
  second/central.Link? := null
  replacement/central.Link? := null
  done := monitor.Latch
  responder := task::
    radio := factory.radio
    fixture.initialize-replies radio
    if peripheral-first:
      accept radio 1 0x234
      links.establish radio 2 0x235
    else:
      links.establish radio 1 0x234
      accept radio 2 0x235
    clients.disconnect radio 0x234
    links.incoming radio 0x235 #[1, 0, 4, 0, 42] --start
    clients.sent radio 0x235 #[43]
    links.establish radio 3 0x234
    links.incoming radio 0x234 #[1, 0, 4, 0, 44] --start
    clients.disconnect radio 0x234
    clients.disconnect radio 0x235
    done.set true
  try:
    pool.setup: | owner/central.Central info/hci.Capabilities |
      host = owner
      first = peripheral-first
          ? owner.accept #[2, 1, 6]
          : owner.connect (links.address 1) --address-type=1
    pool.setup: | owner/central.Central info/hci.Capabilities |
      expect (identical host owner)
      second = peripheral-first
          ? owner.connect (links.address 2) --address-type=1
          : owner.accept #[2, 1, 6]
    expect-equals (peripheral-first ? "1,0" : "0,1") (factory.roles.join ",")
    host.disconnect first
    pool.release
    expect (not pool.released and not factory.radio.closed)
    expect-equals #[42] second.receive.payload
    host.send second 4 #[43]
    pool.retain
    pool.setup: | owner/central.Central info/hci.Capabilities |
      expect (identical host owner)
      replacement = owner.connect (links.address 3) --address-type=1
    expect-equals #[44] replacement.receive.payload
    host.disconnect replacement
    pool.release
    expect (not pool.released and second.connected)
    host.disconnect second
    pool.release
    done.get
    expect pool.released
    expect-equals 1 factory.opens
    expect-equals 1 factory.creates
    expect-equals 1 factory.radio.closes
  finally:
    responder.cancel
    if host:
      host.close
      host.wait-closed

waiting-cancel:
  factory := Factory
  pool := shared.Host factory
  pool.retain
  pool.retain
  ready := monitor.Latch
  stop := monitor.Latch
  first-ended := monitor.Latch
  second-started := monitor.Latch
  second-ended := monitor.Latch
  entered := false
  responder := task:: fixture.initialize-replies factory.radio
  first := task::
    try:
      pool.setup: | owner/central.Central info/hci.Capabilities |
        ready.set true
        stop.get
    finally:
      critical-do --no-respect-deadline:
        pool.release
        first-ended.set true
  second/Task? := null
  try:
    ready.get
    second = task::
      try:
        second-started.set true
        pool.setup: | owner/central.Central info/hci.Capabilities |
          entered = true
      finally:
        critical-do --no-respect-deadline:
          pool.release
          second-ended.set true
    second-started.get
    second.cancel
    second-ended.get
    expect (not entered and not pool.released and not factory.radio.closed)
    stop.set true
    first-ended.get
    expect pool.released
    expect-equals 1 factory.opens
    expect-equals 1 factory.creates
    expect-equals 1 factory.radio.closes
  finally:
    if second: second.cancel
    first.cancel
    responder.cancel
    pool.fail

factory-failure:
  factory := Factory
  factory.reject = true
  pool := shared.Host factory
  pool.retain
  pool.retain
  responder := task:: fixture.initialize-replies factory.radio
  try:
    expect-throw "FIXTURE_HOST_REJECTED": pool.setup: unreachable
    expect factory.radio.closed
    expect-throw "FIXTURE_HOST_REJECTED": pool.setup: unreachable
    expect-throw "GATT_SERVICE_BUSY": pool.retain
    pool.release
    expect (not pool.released)
    pool.release
    expect pool.released
    expect-equals 1 factory.opens
    expect-equals 1 factory.creates
    expect-equals 1 factory.radio.closes
  finally:
    responder.cancel
    pool.fail

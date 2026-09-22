// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.transport
import ble.experimental.service.api as api
import ble.experimental.service.gatt-provider as service
import ble.experimental.service.provider as rpc
import monitor
import .accept-update-cancel as fixture
import .accept-update-exit-app as app

main:
  with-timeout --ms=85_000:
    provider := Provider
    provider.install
    try:
      provider.uninstall --wait
      provider.check 2
      if provider.radios.size != 3 or provider.sessions.size != 3:
        throw "ACCEPT_EXIT_LIFETIME_COUNT"
      print "ACCEPT_EXIT_PROVIDER COMPLETE opens=3 closes=3 interrupted=2 recovered=1"
    finally:
      provider.uninstall

class Provider extends service.Provider:
  radios/List ::= []
  sessions/List ::= []
  begun/Set ::= {}
  ready/monitor.Latch ::= monitor.Latch
  constructor: super
  receive-acl-packets -> int: return 4
  open-transport -> transport.Transport:
    if radios.size >= 3: throw "ACCEPT_EXIT_EXTRA_OPEN"
    radio := fixture.Radio radios.size
    radios.add radio
    return radio
  create-builder client/int name/string -> rpc.Session:
    if sessions.size >= 3: throw "ACCEPT_EXIT_EXTRA_SESSION"
    session := Session this client name
    sessions.add session
    return session
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == app.BEGIN:
      stage/int := arguments
      if not 0 <= stage <= 2 or begun.contains stage: throw "ACCEPT_EXIT_INVALID_STAGE"
      begun.add stage
      if begun.size == 3: ready.set true
      ready.get
      if stage > 0:
        while sessions.size < stage or not sessions[stage - 1].is-released: sleep --ms=1
        check (stage - 1)
        sleep --ms=3_000
      return null
    if index == app.ENABLED:
      while radios.size <= arguments: sleep --ms=1
      radios[arguments].enabled.get
      return null
    if index == app.HELD:
      radios[arguments].held.get
      if not sessions[arguments].updating: throw "ACCEPT_EXIT_NOT_PENDING"
      return null
    return super index arguments --gid=gid --client=client

  check stage/int:
    radio/fixture.Radio := radios[stage]
    session/Session := sessions[stage]
    if not session.is-released: throw "ACCEPT_EXIT_NOT_RELEASED"
    if stage < 2 and not session.closed-with-update: throw "ACCEPT_EXIT_NOT_PENDING_AT_DEATH"
    if session.updating: throw "ACCEPT_EXIT_UPDATE_SURVIVED"
    data := stage < 2 ? 2 : 1
    response := stage < 2 ? stage + 1 : 1
    disables := stage < 2 ? 0 : 1
    if radio.closes != 1 or radio.enables != 1 or radio.disables != disables or
        radio.data-count != data or radio.response-count != response:
      throw "ACCEPT_EXIT_COMMAND_COUNTS"
    print "ACCEPT_EXIT STOPPED stage=$stage closes=1 enables=1 disables=$disables data=$data response=$response"

class Session extends service.Session:
  updating/bool := false
  closed-with-update/bool := false
  constructor provider/Provider client/int name/string:
    super provider client --name=name
  invoke index/int arguments/List -> any:
    if index != api.PERIPHERAL-ADVERTISING-UPDATE: return super index arguments
    updating = true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline: updating = false
  on-closed -> none:
    closed-with-update = updating
    super

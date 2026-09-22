// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import encoding.hex
import monitor
import system
import system.containers
import .hci-echo as fixture

main arguments:
  with-timeout --ms=60_000:
    if arguments is Map:
      application arguments
    else:
      run

run --abrupt/bool=false --first/string="98cdac63762e" --second/string="98cdac60e0ae"
    --receive-acl-packets/int=0:
  provider := Provider --receive-acl-packets=receive-acl-packets
  provider.install
  children := []
  try:
    first-child := containers.start containers.current {"index": 0, "provider": Process.current.id, "abrupt": abrupt, "address": first}
    children.add first-child
    provider.first-ready.get
    second-child := containers.start containers.current {"index": 1, "provider": Process.current.id, "address": second}
    children.add second-child
    if first-child.gid == second-child.gid: throw "EXPECTED_DISTINCT_CONTAINERS"
    print "SERVICE_MULTIPEER GROUPS first=$(first-child.gid) second=$(second-child.gid)"
    if abrupt:
      provider.stop-ready.get
      if first-child.stop != 0: throw "FIRST_CLIENT_STOP_FAILED"
      with-timeout --ms=3_000: provider.stop-unwound.get
      print "SERVICE_MULTIPEER FIRST_STOPPED code=0 rpc-unwound=true"
    else:
      if first-child.wait != 0: throw "FIRST_CLIENT_FAILED"
      print "SERVICE_MULTIPEER FIRST_EXITED code=0"
    provider.first-exited.set true
    if second-child.wait != 0: throw "SECOND_CLIENT_FAILED"
    provider.wait-released
    if provider.opens != 1: throw "CONTROLLER_WAS_REOPENED"
    print "SERVICE_MULTIPEER COMPLETE clients=2 opens=1 exits=0,0"
  finally:
    children.do: it.close
    provider.uninstall

application arguments/Map:
  index/int := arguments["index"]
  client := Client arguments["provider"]
  client.open --timeout=(Duration --s=10)
  try:
    address := hex.decode (arguments.get "address" or (index == 0 ? "98cdac63762e" : "98cdac60e0ae"))
    connection := client.connect address.reverse
    state := connection.security
    if not state.paired or not state.encrypted or not state.authenticated: throw "EXPECTED_AUTHENTICATED_SECURITY"
    services := connection.database.discover-services.filter:
      it.uuid == (fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001")
    if services.size != 1: throw "EXPECTED_ONE_SERVICE"
    characteristics := services[0].characteristics
    values := []
    ["9f6c4001-8e2a-4b13-9e97-94f353eeb001", "9f6c4002-8e2a-4b13-9e97-94f353eeb001"].do: | uuid/string |
      matches := characteristics.filter: it.uuid == (fixture.wire-uuid uuid)
      if matches.size != 1: throw "EXPECTED_ONE_CHARACTERISTIC"
      values.add matches[0]
    base := 42 + index * 40
    retained := [values[0].read, values[1].read]
    client.barrier
    before := system.process-stats --gc
    50.repeat:
      read-values values base
      check-retained retained base
    if index == 1:
      client.wait-first
      state = connection.security
      if not state.encrypted or not state.authenticated: throw "SURVIVOR_SECURITY_LOST"
      20.repeat:
        read-values values base
        check-retained retained base
      print "SERVICE_MULTIPEER SURVIVOR reads=40 encrypted=true"
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 50: throw "GC_COUNT_DID_NOT_ADVANCE"
    print "SERVICE_MULTIPEER CLIENT index=$index reads=$(index == 0 ? 102 : 142) retained=2 full-gcs=$gcs"
    if arguments.get "abrupt":
      client.await-stop
      throw "STOPPED_CLIENT_RETURNED"
    // Closing the client releases its connection without explicit disconnect.
  finally:
    print "SERVICE_MULTIPEER CLIENT_CLEANUP index=$index"
    client.close

read-values values/List base/int:
  if values[0].read != #[base] or values[1].read != #[base + 1]: throw "PROTECTED_VALUE_MISMATCH"

check-retained retained/List base/int:
  system.process-stats --gc
  if retained[0] != #[base] or retained[1] != #[base + 1]: throw "RETAINED_VALUE_CHANGED"

class Client extends clients.Client:
  constructor pid/int:
    super --provider-pid=pid
  barrier: invoke_ 1000 null
  wait-first: invoke_ 1001 null
  await-stop: invoke_ 1002 null

// The extra operations are fixture barriers, not additions to the BLE API.
class Provider extends providers.Provider:
  receive-acl-packets_/int
  observed-sessions_/List ::= []
  first-ready/monitor.Latch ::= monitor.Latch
  both-ready_/monitor.Latch ::= monitor.Latch
  first-exited/monitor.Latch ::= monitor.Latch
  stop-ready/monitor.Latch ::= monitor.Latch
  stop-unwound/monitor.Latch ::= monitor.Latch
  ready_/int := 0
  opens/int := 0

  constructor --receive-acl-packets/int=0:
    receive-acl-packets_ = receive-acl-packets
    super
  receive-acl-packets -> int: return receive-acl-packets_
  central-session-limit -> int: return 2
  create-connection client/int arguments/List -> rpc.Session:
    session := super client arguments
    observed-sessions_.add session
    return session
  wait-released -> none:
    if observed-sessions_.size != 2: throw "EXPECTED_TWO_SESSIONS"
    with-timeout --ms=5_000:
      while true:
        released := true
        observed-sessions_.do: | session/rpc.Session |
          if not session.is-released: released = false
        if released: break
        sleep --ms=1
    print "SERVICE_MULTIPEER RELEASED sessions=2"
  open-transport -> transport.Transport:
    opens++
    return Radio
  create-central-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    if controller.receive-flow-control != (receive-acl-packets_ > 0): throw "RECEIVE_FLOW_CONFIGURATION_MISMATCH"
    print "SERVICE_MULTIPEER RECEIVE_FLOW credits=$receive-acl-packets_"
    return super controller info receive-limit
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return security.Pairing host link --local-address=info.address
        --io-capability=1
        --require-authentication
  run-central-security-owner owner/Owner -> none:
    (owner as security.Pairing).run: | number/int |
      print "SERVICE_MULTIPEER NUMERIC value=$number fixture-approval=true"
      true
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 1000:
      ready_++
      if ready_ == 1: first-ready.set true
      if ready_ == 2: both-ready_.set true
      return both-ready_.get
    if index == 1001: return first-exited.get
    if index == 1002:
      stop-ready.set true
      try:
        return (monitor.Latch).get
      finally:
        critical-do --no-respect-deadline: stop-unwound.set true
    return super index arguments --gid=gid --client=client

class Radio extends esp32.Esp32Transport:
  closed_/bool := false
  constructor: super

  close -> none:
    if closed_: return
    closed_ = true
    try:
      sample := diagnostics
      if sample:
        print "SERVICE_MULTIPEER QUEUE fault=$(sample.fault) high-water=$(sample.high-water) capacity=$(sample.capacity)"
      if not sample or sample.fault: throw "SERVICE_MULTIPEER_NATIVE_QUEUE_FAULT"
    finally:
      super

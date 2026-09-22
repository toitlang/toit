// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as clients
import encoding.hex
import monitor
import system
import system.containers
import .hci-echo as fixture
import .vhci-service-multipeer as shared

main:
  with-timeout --ms=90_000:
    run

run --pending-reads/bool=false --oom/bool=false --provider-containers/bool=false:
  providers := []
  if provider-containers:
    providers.add (containers.start containers.current {"provider": true, "oom": oom})
  else:
    spawn:: provider-main --oom=oom
  first := Client
  second := Client
  first.open --timeout=(Duration --s=5)
  second.open
  try:
    a := first.connect (hex.decode "98cdac63762e").reverse
    b := second.connect (hex.decode "98cdac60e0ae").reverse
    values-a := discover a
    values-b := discover b
    check-security a
    check-security b
    shared.read-values values-a 42
    shared.read-values values-b 82
    retained := [values-a[0].read, values-b[0].read]
    print "PROVIDER_RECOVERY BEFORE links=2 encrypted=true"
    error := null
    if pending-reads:
      terminate-with-reads first values-a[0] values-b[0]
    else:
      error = catch: first.terminate-provider
      if error != "NO_SUCH_PROCESS": throw "EXPECTED_PROVIDER_DEATH"
    [a, b].do: | connection/clients.Connection |
      error = catch: with-timeout --ms=3_000: connection.security
      if error != "NO_SUCH_PROCESS": throw "STALE_CONNECTION_ACCEPTED"
    print "PROVIDER_RECOVERY DEAD stale-connections=2"
    if provider-containers:
      print "PROVIDER_RECOVERY DEAD_CONTAINER exit=$(providers[0].wait)"
      providers.add (containers.start containers.current {"provider": true, "oom": false})
      if providers[0].gid == providers[1].gid: throw "PROVIDER_GROUP_REUSED"
      print "PROVIDER_RECOVERY GROUPS first=$(providers[0].gid) replacement=$(providers[1].gid)"
    else:
      spawn:: provider-main
    fresh := Client
    fresh.open --timeout=(Duration --s=5)
    try:
      current := fresh.connect (hex.decode "98cdac63762e").reverse
      check-security current
      values := discover current
      10.repeat:
        shared.read-values values 42
        system.process-stats --gc
        if retained[0] != #[42] or retained[1] != #[82]: throw "RETAINED_VALUE_CHANGED"
      error = catch: values-a[0].read
      if error != "NO_SUCH_PROCESS": throw "STALE_VALUE_REBOUND"
      current.disconnect
      error = catch: fresh.terminate-provider
      if error != "NO_SUCH_PROCESS": throw "EXPECTED_REPLACEMENT_EXIT"
      print "PROVIDER_RECOVERY COMPLETE replacement-reads=20 stale-value=invalid retained=2"
    finally:
      fresh.close
  finally:
    first.close
    second.close
    providers.do: it.close

terminate-with-reads client/Client a/clients.CharacteristicRecord b/clients.CharacteristicRecord:
  results := [monitor.Latch, monitor.Latch]
  workers := []
  completed := false
  try:
    error := catch:
      a.subscribe: | first/clients.Subscription |
        b.subscribe: | second/clients.Subscription |
          workers.add (task:: results[0].set (catch: a.read))
          workers.add (task:: results[1].set (catch: b.read))
          with-timeout --ms=3_000:
            if first.receive != #[42] or second.receive != #[82]: throw "PENDING_MARKER_MISMATCH"
          if (results.any: it.has-value): throw "READ_NOT_PENDING"
          print "PROVIDER_RECOVERY PENDING reads=2 peer-markers=true"
          failure := catch: client.terminate-provider
          if failure != "NO_SUCH_PROCESS": throw "EXPECTED_PROVIDER_DEATH"
          results.do: | result/monitor.Latch |
            failure = with-timeout --ms=3_000: result.get
            if failure != "NO_SUCH_PROCESS": throw "PENDING_READ_NOT_FAILED"
          print "PROVIDER_RECOVERY READS_FAILED count=2 error=NO_SUCH_PROCESS"
          completed = true
    // Subscription cleanup can observe the provider's already-confirmed death.
    if error and error != "NO_SUCH_PROCESS": throw error
    if not completed: throw "PENDING_RECOVERY_INCOMPLETE"
  finally:
    workers.do: it.cancel

discover connection/clients.Connection -> List:
  services := connection.database.discover-services.filter:
    it.uuid == (fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001")
  if services.size != 1: throw "EXPECTED_ONE_SERVICE"
  characteristics := services[0].characteristics
  return ["9f6c4001-8e2a-4b13-9e97-94f353eeb001", "9f6c4002-8e2a-4b13-9e97-94f353eeb001"].map: | uuid/string |
    matches := characteristics.filter: it.uuid == (fixture.wire-uuid uuid)
    if matches.size != 1: throw "EXPECTED_ONE_CHARACTERISTIC"
    matches[0]

check-security connection/clients.Connection:
  state := connection.security
  if not state.paired or not state.encrypted or not state.authenticated: throw "EXPECTED_AUTHENTICATED_SECURITY"

provider-main --oom/bool=false:
  provider := Provider --oom=oom
  provider.install
  print "PROVIDER_RECOVERY PROVIDER pid=$(Process.current.id)"
  (monitor.Latch).get

class Client extends clients.Client:
  constructor: super
  terminate-provider: invoke_ 1003 null

class Provider extends shared.Provider:
  oom_/bool
  constructor --oom/bool=false:
    oom_ = oom
    super
  handle index/int arguments/any --gid/int --client/int -> any:
    // Fixture-only exit kills the owning process without provider cleanup.
    if index == 1003:
      if oom_:
        // An unhandled task allocation failure must terminate the process;
        // an ordinary RPC exception would not exercise resource reclamation.
        task::
          set-max-heap-size_ (256 * 1024)
          print "PROVIDER_RECOVERY OOM_ARMED heap-limit=262144"
          ballast := []
          while true: ballast.add (ByteArray 128 --initial=42)
        (monitor.Latch).get
      exit 0
    return super index arguments --gid=gid --client=client

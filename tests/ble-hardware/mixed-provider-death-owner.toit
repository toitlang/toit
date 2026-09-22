// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import .mixed-central-death-provider as fixture
import .mixed-service-client as protocol

INFO ::= 1002
CHECK-SECURITY ::= 1003

main:
  provider := Provider
  provider.install
  print "MIXED_PROVIDER_DEATH OWNER pid=$(Process.current.id)"
  try:
    (monitor.Latch).get
  finally:
    print "MIXED_PROVIDER_DEATH OWNER_FINALLY_RAN"
    provider.uninstall

class Provider extends fixture.Provider:
  waiting_/Set ::= {}

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == INFO:
      return [Process.current.id, opens, radio ? radio.closes : 0,
        radio ? radio.read-requests : 0,
        last-central != null and last-central.is-released,
        last-peripheral != null and last-peripheral.is-released]
    if index == protocol.WAIT and arguments == 15:
      if waiting_.contains client: throw "MIXED_DUPLICATE_WAITER"
      waiting_.add client
      if waiting_.size == 2: publish 2
    return super index arguments --gid=gid --client=client

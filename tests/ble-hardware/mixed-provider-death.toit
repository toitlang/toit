// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.containers
import .mixed-service-client as fixture
import .mixed-service-provider as images
import .mixed-provider-death-owner as owner

main:
  with-timeout --ms=160_000: run

run --pending/bool=false --authenticated/bool=false:
  children := []
  controls := []
  try:
    first := images.start "mixed-provider" []
    children.add first
    admin := Control
    controls.add admin
    admin.open --timeout=(Duration --s=10)
    central := images.start "mixed-central" [pending, authenticated]
    children.add central
    peripheral := images.start "mixed-periph" [pending, authenticated]
    children.add peripheral
    admin.wait 2
    before := admin.info
    if before[1] != 1 or before[2] != 0 or before[3] != 100: throw "MIXED_BEFORE_DEATH"
    if authenticated: admin.check-security false
    if pending: print "MIXED_PROVIDER_PENDING ARMED reads=2 peer-marker=true callback=true"
    start := Time.monotonic-us
    if first.stop != 0: throw "MIXED_OWNER_STOP"
    first.close
    replacement := images.start "mixed-provider" []
    children.add replacement
    fresh := Control
    controls.add fresh
    with-timeout --ms=5_000:
      fresh.open --timeout=(Duration --s=3)
      fresh.wait 3
      fresh.wait 4
    print "MIXED_PROVIDER_DEATH CLIENTS_FAILED_AND_REOPENED elapsed-us=$(Time.monotonic-us - start)"
    fresh.wait 5
    fresh.wait 6
    if central.wait != 0 or peripheral.wait != 0: throw "MIXED_CLIENT_EXIT"
    central.close
    peripheral.close
    after := fresh.info
    print "MIXED_PROVIDER_DEATH RELEASE_STARTED stats=$after"
    release-start := Time.monotonic-us
    // Client closure starts provider cleanup; wait for both resource owners.
    with-timeout --ms=4_000:
      while not after[4] or not after[5]:
        sleep --ms=1
        after = fresh.info
    print "MIXED_PROVIDER_DEATH RELEASE_COMPLETE elapsed-us=$(Time.monotonic-us - release-start) stats=$after"
    if before[0] == after[0] or first.gid == replacement.gid: throw "MIXED_PROVIDER_NOT_REPLACED"
    if after[1] != 1 or after[2] != 1 or after[3] != 100: throw "MIXED_REPLACEMENT_LIFETIME"
    if authenticated: fresh.check-security true
    if (catch: admin.info) != "NO_SUCH_PROCESS": throw "MIXED_STALE_ADMIN_REBOUND"
    if replacement.stop != 0: throw "MIXED_REPLACEMENT_STOP"
    replacement.close
    print "MIXED_PROVIDER_DEATH COMPLETE old-pid=$(before[0]) new-pid=$(after[0]) old-gid=$(first.gid) new-gid=$(replacement.gid) central-reads=200 peer-reads=200 local-reads=200"
  finally:
    controls.do: it.close
    children.do: | container/containers.Container |
      if not container.is-closed: container.stop
      container.close

class Control extends fixture.Client:
  info -> List: return invoke_ owner.INFO null
  check-security closed/bool -> none: invoke_ owner.CHECK-SECURITY closed

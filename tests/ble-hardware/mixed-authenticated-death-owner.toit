// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner show Owner
import ble.experimental.service.mixed-provider as policy
import monitor
import .mixed-provider-death-owner as fixture
import .mixed-resume-provider as resume
import .mixed-resume-state as saved

main: run

run --receive-acl-packets/int=0:
  state := saved.State (bond-flash.FlashRecords "toit.test/ble-mixed-resume-001-s3")
      [saved.PEER, saved.LINUX]
      "S3"
      --resume-only
  provider := Provider state receive-acl-packets
  provider.install
  print "MIXED_PROVIDER_DEATH OWNER pid=$(Process.current.id)"
  print "MIXED_AUTHENTICATED_DEATH RECEIVE_CREDITS packets=$receive-acl-packets"
  try:
    (monitor.Latch).get
  finally:
    print "MIXED_PROVIDER_DEATH OWNER_FINALLY_RAN"
    provider.uninstall
    state.close

class Provider extends fixture.Provider:
  state_/saved.State
  host_/resume.Host? := null
  receive-acl-packets_/int
  constructor .state_ .receive-acl-packets_: super

  receive-acl-packets -> int: return receive-acl-packets_

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    policy.configure controller info
    if info.address != saved.S3: throw "MIXED_RESUME_WRONG_BOARD"
    host_ = resume.Host controller info receive-limit state_
    return host_

  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (host as resume.Host).owners[link.info.handle]

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (host as resume.Host).owners[link.info.handle]

  run-central-security-owner selected/Owner -> none: state_.secure selected 0
  run-security-owner selected/Owner -> none: state_.secure selected 1

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == fixture.CHECK-SECURITY:
      if state_.fresh != 0 or state_.resumed != 2: throw "MIXED_SECURITY_COUNTS"
      if arguments: state_.check 0 2
      else:
        if host_.owners.size != 2: throw "MIXED_SECURITY_OWNERS"
        host_.owners.values.do: | owner/Owner |
          if not owner.encrypted or not owner.authenticated: throw "MIXED_SECURITY_LOST"
      print "MIXED_AUTHENTICATED_DEATH OWNER_CHECK closed=$arguments fresh=0 resumed=2"
      return null
    return super index arguments --gid=gid --client=client

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import ble.experimental.central
import ble.experimental.extended-scanning
import ble.experimental.hci
import ble.experimental.scanning
import ble.experimental.service.mixed-provider as policy
import encoding.hex
import .mixed-independent-bond-provider as addresses
import .mixed-resume-provider as resume
import .mixed-resume-state as saved
import .mixed-service-provider as fixture

main:
  state := saved.State (bond-flash.FlashRecords "toit.test/ble-mixed-independent-private-v1-owner")
      [addresses.PEER, saved.LINUX]
      "S3"
      --resume-only
      --exchange-identities
  try:
    print "MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer=$(hex.encode saved.LINUX.reverse)"
    print "MIXED_INDEPENDENT_BOND OWNER resume-only=true"
    [false, true].do: | peripheral-first/bool |
      with-timeout --ms=160_000:
        fixture.run peripheral-first (Provider state) --peer-reads=202 --central-peer=saved.LINUX
    state.check 0 6
    print "MIXED_PROVIDER COMPLETE rounds=2"
  finally:
    state.close

class Provider extends resume.Provider:
  state_/saved.State
  constructor .state_: super state_

  receive-acl-packets -> int: return 4

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    if info.address != saved.S3: throw "MIXED_RESUME_WRONG_BOARD"
    peer := (state_.table.load 1).peer
    if peer.address != saved.LINUX or not peer.has-resolving-key: throw "MIXED_PRIVATE_WRONG_IDENTITY"
    target/ByteArray? := null
    statistics := scanning.Statistics
    // Discover before creating the host or starting either radio role. Scanning
    // remains exclusive, within this round's single controller lifetime.
    with-timeout --ms=15_000:
      extended-scanning.scan controller info --statistics=statistics: | report |
        if report.address-type != 1 or not (report.has-service #[0xf0, 0xff]) or
            not (peer.matches report.address --address-type=report.address-type):
          continue.scan true
        target = report.address.copy
        false
    if not target or not statistics.stopped: throw "MIXED_PRIVATE_DISCOVERY_FAILED"
    print "MIXED_PRIVATE_DISCOVERED peer=$(hex.encode target.reverse) identity=$(hex.encode peer.address.reverse) stopped=true"
    policy.configure controller info
    return Host controller info receive-limit state_ target

class Host extends resume.Host:
  target_/ByteArray
  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int state/saved.State .target_:
    super controller info receive-limit state

  connect address/ByteArray --address-type/int
      --timeout/Duration=(Duration --s=10) --local-random-address/ByteArray?=null -> central.Link:
    if address != saved.LINUX or address-type != 0 or local-random-address:
      throw "MIXED_PRIVATE_UNEXPECTED_TARGET"
    // This laboratory provider accepts one saved identity from its client.
    // Security still resolves and authenticates the actual connection address.
    return super target_ --address-type=1 --timeout=timeout

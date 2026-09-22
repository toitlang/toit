// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.security-owner show Owner
import ble.experimental.service.pairing-provider as service

main:
  run

run --receive-flow/bool=false --authenticated/bool=false:
  provider := Provider --receive-flow=receive-flow --authenticated=authenticated
  provider.install
  try:
    provider.uninstall --wait
    print "COMMAND_OVERLOAD_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  receive-flow_/bool
  authenticated_/bool
  constructor --receive-flow/bool=false --authenticated/bool=false:
    receive-flow_ = receive-flow
    authenticated_ = authenticated
    super

  local-random-address -> ByteArray?: return #[3, 0x30, 0x23, 0xf2, 0x3a, 0xc8]

  receive-acl-packets -> int: return receive-flow_ ? 4 : 0
  pairing-io-capability -> int?: return authenticated_ ? 1 : null
  require-authentication -> bool: return authenticated_
  confirm-pairing number/int -> bool:
    print "COMMAND_OVERLOAD_PROVIDER NUMERIC value=$number fixture-approval=true"
    return true
  run-security-owner owner/Owner -> none:
    super owner
    if not owner.encrypted or not owner.authenticated: throw "EXPECTED_AUTHENTICATED_SECURITY"
    print "COMMAND_OVERLOAD_PROVIDER AUTHENTICATED encrypted=true authenticated=true"

  open-transport -> transport.Transport: return Radio

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    return Host controller info receive-limit

class Host extends central.Central:
  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int:
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit

  abort link/central.Link --error="HCI_LINK_CLOSED" -> none:
    print "COMMAND_OVERLOAD_PROVIDER ABORT error=$error high-water=$(link.receive-high-water) us=$(Time.monotonic-us)"
    super link --error=error

class Radio extends esp32.Esp32Transport:
  closed_/bool := false
  constructor: super

  close -> none:
    if closed_: return
    closed_ = true
    try:
      sample := diagnostics
      if sample:
        print "COMMAND_OVERLOAD_PROVIDER FINAL_QUEUE fault=$(sample.fault) capacity=$(sample.capacity) queued=$(sample.queued) high-water=$(sample.high-water) scan-drops=$(sample.scan-drops)"
    finally:
      super

  receive -> ByteArray:
    packet/ByteArray? := null
    error := catch: packet = super
    if error:
      print "COMMAND_OVERLOAD_PROVIDER TRANSPORT_ERROR error=$error us=$(Time.monotonic-us)"
      sample := diagnostics
      if sample:
        print "COMMAND_OVERLOAD_PROVIDER QUEUE fault=$(sample.fault) capacity=$(sample.capacity) queued=$(sample.queued) high-water=$(sample.high-water) scan-drops=$(sample.scan-drops)"
      throw error
    if packet.size == 4 and packet[..3] == #[4, 0x10, 1]:
      print "COMMAND_OVERLOAD_PROVIDER HARDWARE_ERROR code=$(packet[3])"
    return packet

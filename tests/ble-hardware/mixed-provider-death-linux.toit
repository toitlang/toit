// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import encoding.hex
import io
import .mixed-service-client as fixture
import .mixed-resume-state as saved

main args/List:
  if not 2 <= args.size <= 3: throw "Usage: mixed-provider-death-linux.toit INDEX PUBLIC_ADDRESS [pending|pending-spaced]"
  pending := args.size == 3
  spaced := pending and args[2] == "pending-spaced"
  if pending and args[2] != "pending" and not spaced: throw "INVALID_ARGUMENT"
  address := (hex.decode (args[1].replace --all ":" "")).reverse
  run (int.parse args[0]) address --pending=pending --spaced=spaced

run index/int address/ByteArray --pending/bool=false --spaced/bool=false --state/saved.State?=null:
  controller := hci.Controller (linux.LinuxTransport index)
  host/central.Central? := null
  try:
    info := hci.initialize controller
    if state and info.address != saved.LINUX: throw "MIXED_RESUME_WRONG_ADAPTER"
    host = spaced
        ? (IntervalCentral controller info)
        : (central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count)
    2.repeat: | cycle/int |
      link := host.connect address --address-type=0 --timeout=(Duration --s=40)
      owner := state and (state.owner host link info.address)
      client := att.Client host link --pairing=owner
      try:
        if state:
          error := catch: client.read 14
          if not (error is att.AttributeError) or error.code != 5: throw "MIXED_EXPECTED_PROTECTED_DENIAL"
          print "MIXED_AUTHENTICATED_DEATH LINUX_DENIED cycle=$cycle code=5"
          state.secure owner 0
        fixture.check-values:
          if state and not owner.authenticated: throw "MIXED_AUTHENTICATION_LOST"
          client.read 3
        if pending and cycle == 0:
          // Observe controller link loss, which can take longer than read's
          // default three-second operation deadline after abrupt provider death.
          error := catch: client.request #[0x0a, 14, 0] --response=0x0b --timeout=(Duration --s=15)
          print "MIXED_PROVIDER_PENDING LINUX_READ_RESULT error=$error"
          if error != "HCI_LINK_DISCONNECTED": throw "MIXED_INCOMING_READ_NOT_FAILED"
          print "MIXED_PROVIDER_PENDING LINUX_READ_FAILED error=HCI_LINK_DISCONNECTED"
        else:
          client.write-command 12 #[1]
        reason := with-timeout --ms=15_000: link.wait-disconnected
        if cycle == 1 and reason != 0x13: throw "MIXED_REPLACEMENT_DISCONNECT_REASON"
        print "MIXED_PROVIDER_DEATH LINUX_CYCLE cycle=$cycle reads=100 reason=$reason"
      finally:
        client.close
    host.close
    host.wait-closed
    if state: state.check 0 2
    print "MIXED_PROVIDER_DEATH LINUX_COMPLETE reads=200"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

// Diagnostic policy only: change the Linux-owned link from the ordinary
// 30–50ms range to fixed60ms, leaving both board images and initiating policy
// unchanged. A successful run does not establish a production workaround.
class IntervalCentral extends central.Central:
  constructor controller/hci.Controller info/hci.Capabilities:
    super controller --acl-length=info.acl-length --acl-count=info.acl-count

  encode-connection address/ByteArray --address-type/int --own-address-type/int -> ByteArray:
    bytes := super address --address-type=address-type --own-address-type=own-address-type
    io.LITTLE-ENDIAN.put-uint16 bytes 13 48
    io.LITTLE-ENDIAN.put-uint16 bytes 15 48
    print "MIXED_PROVIDER_PENDING LINUX_INTERVAL units=48 milliseconds=60 diagnostic=true"
    return bytes

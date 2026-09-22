// Copyright (C) 2026 Toit contributors.
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.central
import ble.experimental.scanning
import ble.experimental.advertising
import ble.experimental.security
import ble.experimental.att
import ble.experimental.smp-pairing as smp
import .provider as fixture

main:
  with-timeout --ms=90_000:
    3.repeat: | round/int |
      if round != 0: sleep --ms=500
      run round
  print "RETRY_PEER COMPLETE"

run round/int:
  controller := hci.Controller fixture.Radio
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    peer/advertising.Report? := null
    with-timeout --ms=25_000:
      scanning.scan controller: | report/advertising.Report |
        if not (report.has-service #[0xe0 + round, 0xff]): continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    if round == 0:
      reject-with-controller-held host link info
      return
    owner := security.Pairing host link --local-address=info.address --io-capability=1 --require-authentication
    client = att.Client host link --pairing=owner
    comparisons := 0
    error := catch:
      owner.run: | number/int |
        comparisons++
        print "RETRY_PEER NUMERIC round=$round value=$number"
        true
    if round == 0 and (not error or comparisons != 1): throw "EXPECTED_REJECTION"
    if round == 1 and (not error or comparisons != 0 or owner.encrypted): throw "EXPECTED_EARLY_REFUSAL"
    if round == 2:
      if error: throw error
      if not owner.encrypted or not owner.authenticated: throw "EXPECTED_AUTHENTICATION"
      if (client.read 12) != #[42]: throw "READ_MISMATCH"
      host.disconnect link
    print "RETRY_PEER RESULT round=$round error=$error encrypted=$(owner.encrypted) comparisons=$comparisons"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

// Controlled test peer: do not reset the controller immediately on rejection.
// Hold it for the rejector's three-second drain bound, without claiming that
// elapsed time establishes packet completion or successful protocol cleanup.
reject-with-controller-held host/central.Central link/central.Link info/hci.Capabilities:
  engine := smp.Session --initiator --io-capability=1 --require-authentication
      --local-address=(#[0] + info.address.reverse)
      --peer-address=(#[link.info.address-type] + link.info.address.reverse)
  try:
    engine.start.do: | bytes/ByteArray | host.send link 6 bytes
    comparisons := 0
    with-timeout --ms=15_000:
      while true:
        packet := link.receive
        if packet.channel == 5:
          if packet.payload[0] != 0x12: throw "UNEXPECTED_SIGNAL"
          host.send link 5 #[0x13, packet.payload[1], 2, 0, 0, 0]
          continue
        if packet.channel != 6: throw "UNEXPECTED_CHANNEL"
        if packet.payload == #[5, 12]: break
        (engine.receive packet.payload).do: | bytes/ByteArray | host.send link 6 bytes
        if engine.comparison-number != null:
          comparisons++
          print "RETRY_PEER NUMERIC round=0 value=$(engine.comparison-number)"
          (engine.approve true).do: | bytes/ByteArray | host.send link 6 bytes
    if comparisons != 1 or link.encrypted: throw "EXPECTED_REJECTION"
    print "RETRY_PEER RESULT round=0 error=SMP_PAIRING_FAILED reason=12 encrypted=false comparisons=1 controller-held=true"
    sleep --ms=3_500
  finally:
    engine.close

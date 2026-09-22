// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.bond-storage
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import host.file
import .mixed-service-client as fixture
import .mixed-resume-state as saved

main args/List:
  if args.size != 3 or not (["pair", "resume"].contains args[2]):
    throw "Usage: mixed-resume-linux.toit <adapter index> <record file> <pair|resume>"
  resume-only := args[2] == "resume"
  state := saved.State (Records args[1]) [saved.S3] "LINUX" --resume-only=resume-only
  run state (linux.LinuxTransport (int.parse args[0])) saved.LINUX

run state/saved.State radio/transport.Transport local/ByteArray:
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    if info.address != local: throw "MIXED_RESUME_WRONG_ADAPTER"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    4.repeat: | cycle/int |
      link := host.connect saved.S3 --address-type=0 --timeout=(Duration --s=40)
      owner := state.owner host link info.address
      client := att.Client host link --pairing=owner
      try:
        error := catch: client.read 12
        if not (error is att.AttributeError) or error.code != 5: throw "MIXED_EXPECTED_PROTECTED_DENIAL"
        state.secure owner 0
        fixture.check-values:
          if not owner.encrypted or not owner.authenticated: throw "MIXED_SECURITY_LOST"
          client.read 12
        client.write-command 14 #[1]
        reason := with-timeout --ms=30_000: link.wait-disconnected
        if reason != 0x13: throw "MIXED_PEER_DISCONNECT_REASON"
        print "MIXED_RESUME LINUX CYCLE cycle=$cycle protected-reads=100 denied=1"
      finally:
        client.close
    host.close
    host.wait-closed
    state.check (state.resume-only ? 0 : 1) (state.resume-only ? 4 : 3)
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
    state.close

// One protected record, private file permissions and same-directory rename.
// This fixture does not assert crash durability or provision a production key.
class Records implements bond-storage.Records:
  path_/string
  constructor .path_:
  namespace -> ByteArray: return "fixture:ble-mixed-resume-001-linux".to-byte-array
  read name/string -> ByteArray?:
    if not (file.stat path_): return null
    return file.read-contents path_
  write name/string bytes/ByteArray -> none:
    temporary := "$(path_).next"
    file.write-contents bytes --path=temporary --permissions=0x180
    file.rename temporary path_
  remove name/string -> none:
    if file.stat path_: file.delete path_
  close -> none:

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure
    uuid := fixture.wire-uuid "9f6c5000-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    handle := session.add-characteristic (fixture.wire-uuid "9f6c5001-8e2a-4b13-9e97-94f353eeb001")
        --read
        --write-command
        --validate-write
        --value=#[7]
    session.start (#[2, 1, 6, 17, 7] + uuid)
    print "LOCAL_COMMAND_APP READY"
    peer := session.peer
    if peer != [#[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8], 0]: throw "WRONG_PEER"
    accepted := []
    validations := 0
    rejected := 0
    session.serve
        (: | _ | unreachable)
        (: | request/service.Request |
          if request.handle != handle or request.opcode != 0x52: throw "WRONG_COMMAND"
          validations++
          if request.value == #[99]:
            rejected++
            request.reject 0x13
          else:
            expected := accepted.is-empty ? (ByteArray 20: it) : #[]
            if accepted.size >= 2 or request.value != expected: throw "WRONG_COMMAND_VALUE"
            request.accept)
        (: | actual/int value/ByteArray |
          if actual != handle: throw "WRONG_HANDLE"
          accepted.add value
          system.process-stats --gc)
    if validations != 3 or rejected != 1 or accepted != [(ByteArray 20: it), #[]]:
      throw "INCOMPLETE_COMMAND_TEST"
    print "LOCAL_COMMAND_APP COMPLETE accepted=2 rejected=1 retained=true"
  finally:
    client.close

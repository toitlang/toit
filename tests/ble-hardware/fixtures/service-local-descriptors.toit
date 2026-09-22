// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main: run

run --value-length/int=20 --encrypted/bool=false --authenticated/bool=false --expect-denied/bool=false
    --peer/ByteArray=#[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]:
  if not 1 <= value-length <= 512 or peer.size != 6: throw "INVALID_ARGUMENT"
  if expect-denied and not authenticated: throw "INVALID_ARGUMENT"
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure --value-limit=(max 20 value-length)
    uuid := fixture.wire-uuid "9f6c6000-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    value := session.add-characteristic (fixture.wire-uuid "9f6c6001-8e2a-4b13-9e97-94f353eeb001") --read --dynamic-read=expect-denied
    session.add-descriptor value #[1, 0x29] --value="Toit descriptor".to-byte-array
    descriptor := session.add-descriptor value (fixture.wire-uuid "9f6c6002-8e2a-4b13-9e97-94f353eeb001")
        --write
        --encrypted=encrypted
        --authenticated=authenticated
        --value=#[7]
    session.start (#[2, 1, 6, 17, 7] + uuid)
    print "LOCAL_DESCRIPTOR_APP READY"
    if session.peer != [peer, 0]: throw "WRONG_PEER"
    values := []
    checks := 0
    session.serve
        (: | request/service.Request |
          if not expect-denied or request.handle != value: throw "UNEXPECTED_READ"
          state := session.security
          if not state.encrypted or state.authenticated: throw "EXPECTED_UNAUTHENTICATED_ENCRYPTION"
          if (session.value descriptor) != #[7]: throw "DENIED_WRITE_CHANGED_VALUE"
          checks++
          request.reply #[7])
        (: | _ | unreachable)
        (: | handle/int bytes/ByteArray |
          if expect-denied or handle != descriptor or values.size >= 2: throw "UNEXPECTED_DESCRIPTOR_WRITE"
          expected := values.is-empty ? (ByteArray value-length: it % 251) : #[]
          if bytes != expected: throw "DESCRIPTOR_VALUE_MISMATCH"
          values.add bytes
          system.process-stats --gc)
    if expect-denied:
      if not values.is-empty or checks != 1: throw "INCOMPLETE_DENIAL_TEST"
      print "LOCAL_DESCRIPTOR_APP COMPLETE writes=0 unchanged=true security-checked=true"
      return
    if values != [(ByteArray value-length: it % 251), #[]]: throw "INCOMPLETE_DESCRIPTOR_TEST"
    print "LOCAL_DESCRIPTOR_APP COMPLETE writes=2 retained=true"
  finally:
    client.close

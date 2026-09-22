// Copyright (C) 2026 Toit contributors.
import ble.experimental.service.client as service
import system

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    3.repeat: | round/int |
      if round == 2: sleep --ms=11_000
      session := client.configure
      session.add-service #[0xe0 + round, 0xff]
      handle := session.add-characteristic #[0xf1, 0xff] --read --authenticated --dynamic-read
      session.start #[2, 1, 6, 3, 3, 0xe0 + round, 0xff]
      print "RETRY_APP READY round=$round"
      reads := 0
      error := catch:
        session.peer
        session.serve
            (: | request/service.Request |
              if round != 2 or request.handle != handle: throw "UNEXPECTED_READ"
              state := session.security
              if not state.encrypted or not state.authenticated: throw "UNPROTECTED_READ"
              value := #[42].copy
              system.process-stats --gc
              request.reply value
              reads++)
            (: unreachable)
            (: unreachable)
      session.close
      if round == 0 and error != "SMP_PAIRING_FAILED reason=12": throw "FIRST_REJECTION_MISSING: $error"
      if round == 1 and error != "SMP_REPEATED_ATTEMPTS": throw "RETRY_REFUSAL_MISSING: $error"
      if round == 2 and (error or reads != 1): throw "RECOVERY_FAILED: $error reads=$reads"
      print "RETRY_APP RESULT round=$round error=$error reads=$reads"
    print "RETRY_APP COMPLETE"
  finally:
    client.close

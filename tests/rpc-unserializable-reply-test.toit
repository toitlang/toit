// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import rpc
import rpc.broker show RpcBroker

// Tests that a procedure that returns a value that can't be serialized
// makes the call fail, and that the provider keeps answering calls.

PROCEDURE-READY ::= 620
PROCEDURE-ECHO ::= 621
PROCEDURE-UNSERIALIZABLE ::= 622
PROCEDURE-STOP ::= 623

class Unserializable:

main:
  broker := RpcBroker
  broker.install
  ready := monitor.Latch
  broker.register-procedure PROCEDURE-READY:: | _ _ pid | ready.set pid
  parent := Process.current.id
  spawn:: provider parent
  provider-pid := with-timeout --ms=10_000: ready.get

  2.repeat:
    expect-throw "SERIALIZATION_FAILED":
      with-timeout --ms=10_000: rpc.invoke provider-pid PROCEDURE-UNSERIALIZABLE null
    expect-equals 42
        with-timeout --ms=10_000: rpc.invoke provider-pid PROCEDURE-ECHO 42

  rpc.invoke provider-pid PROCEDURE-STOP null

provider parent/int:
  stop := monitor.Latch
  broker := RpcBroker
  broker.register-procedure PROCEDURE-ECHO:: | arguments | arguments
  broker.register-procedure PROCEDURE-UNSERIALIZABLE:: Unserializable
  broker.register-procedure PROCEDURE-STOP:: stop.set true
  broker.install
  rpc.invoke parent PROCEDURE-READY null
  stop.get

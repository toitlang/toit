// Copyright (C) 2022 Toitware ApS. All rights reserved.

import rpc
import ..tools.rpc show RpcBroker
import expect

PROCEDURE_MULTIPLY_BY_TWO/int ::= 500

main:
  myself := current_process_
  broker := RpcBroker
  broker.install

  broker.register_procedure PROCEDURE_MULTIPLY_BY_TWO:: | args |
    args[0] * 2

  10.repeat:
    expect.expect_equals
        it * 2
        rpc.invoke myself PROCEDURE_MULTIPLY_BY_TWO [it]

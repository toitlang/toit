// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rpc
import rpc.broker show RpcBroker
import system.services

SELECTOR ::= services.ServiceSelector
    --uuid="285e11d4-9387-4c95-9c36-41c9ac790c8a"
    --major=0
    --minor=0

main:
  with-timeout --ms=5_000:
    spawn::
      provider := Provider
      provider.install
      provider.uninstall --wait
    broker := RpcBroker
    broker.register-procedure 123:: | value | value
    broker.install
    expect-equals 42 (rpc.invoke Process.current.id 123 42)
    client := Client
    client.open --timeout=(Duration --s=1)
    try:
      expect-equals 7 client.read
      // Subscribing to provider-death notifications must not install a second
      // RPC request broker over the application's existing handler.
      expect-equals 43 (rpc.invoke Process.current.id 123 43)
    finally:
      client.close
    expect-equals 44 (rpc.invoke Process.current.id 123 44)

class Client extends services.ServiceClient:
  constructor: super SELECTOR
  read -> int: return invoke_ 0 null

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  constructor:
    super "client-broker-test" --major=0 --minor=0
    provides SELECTOR --handler=this
  handle index/int arguments/any --gid/int --client/int -> any:
    expect-equals 0 index
    return 7

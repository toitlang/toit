// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import encoding.hex
import system.containers
import .vhci-provider-recovery show discover

main arguments:
  with-timeout --ms=60_000:
    if arguments is Map:
      application arguments["provider"]
    else:
      provider := Provider
      provider.install
      try:
        child := containers.start containers.current {"provider": Process.current.id}
        try:
          if child.wait != 0: throw "SECURITY_REQUIREMENTS_APPLICATION_FAILED"
          if provider.opens != 3: throw "EXPECTED_THREE_CONTROLLER_LIFETIMES"
          print "SECURITY_REQUIREMENTS COMPLETE client-exit=0 controller-opens=3"
        finally:
          child.close
      finally:
        provider.uninstall

application pid/int:
  client := clients.Client --provider-pid=pid
  client.open
  address := (hex.decode "98cdac63762e").reverse
  try:
    client.with-connection address --require-encryption: | connection/clients.Connection |
      state := connection.security
      if not state.encrypted or state.authenticated: throw "EXPECTED_JUST_WORKS"
      values := discover connection
      if values[0].read != #[42]: throw "ENCRYPTED_READ_FAILED"
      print "SECURITY_REQUIREMENTS ENCRYPTION_ACCEPTED value=42"
    entered := false
    error := catch:
      client.with-connection address --require-authentication: | connection/clients.Connection |
        entered = true
    if error != "GATT_CENTRAL_SECURITY_REQUIRED" or entered: throw "UNAUTHENTICATED_CONNECTION_ACCEPTED"
    print "SECURITY_REQUIREMENTS AUTHENTICATION_REJECTED body-entered=false"
    client.with-connection address --require-authentication: | connection/clients.Connection |
      state := connection.security
      if not state.encrypted or not state.authenticated: throw "EXPECTED_AUTHENTICATED_PAIRING"
      values := discover connection
      if values[0].read != #[42] or values[1].read != #[43]: throw "AUTHENTICATED_READ_FAILED"
      print "SECURITY_REQUIREMENTS AUTHENTICATION_ACCEPTED values=42,43"
  finally:
    client.close

class Provider extends providers.Provider:
  opens/int := 0

  constructor: super
  open-transport -> transport.Transport:
    opens++
    return esp32.Esp32Transport
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return security.Pairing host link --local-address=info.address
        --io-capability=(opens == 3 ? 1 : 3)
        --require-authentication=(opens == 3)
  run-central-security-owner selected/Owner -> none:
    (selected as security.Pairing).run: | number/int |
      if opens != 3: throw "UNEXPECTED_NUMERIC_COMPARISON"
      print "SECURITY_REQUIREMENTS NUMERIC value=$number fixture-approval=true"
      true

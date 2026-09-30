// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Peers named by a platform identifier (macOS): a provider reports 16-byte
// identifiers with address type 4, the API gives PlatformPeer objects, and
// connect sends the identifier back.

import expect show *
import monitor
import ble.v2 as ble
import ble.experimental.service.api as api
import ble.experimental.service.provider as rpc

IDENTIFIER ::= ByteArray 16: it * 17

main:
  with-timeout --ms=5_000:
    provider := Provider
    provider.install
    adapter := ble.Adapter
    try:
      report := adapter.find --duration=(Duration --s=1)
      peer := report.peer
      expect peer is ble.PlatformPeer
      expect-null report.address
      expect-equals IDENTIFIER (peer as ble.PlatformPeer).bytes
      expect-equals "00112233-4455-6677-8899-aabbccddeeff" peer.stringify
      expect-equals "T" report.name
      expect-equals (ble.PlatformPeer IDENTIFIER) peer
      connection := adapter.connect peer --mtu=23
      expect-equals peer connection.peer
      expect-equals [IDENTIFIER, 4] provider.connected
      expect-equals 27 connection.data-length.tx-octets
      connection.close
      expect-throw "INVALID_ARGUMENT": ble.PlatformPeer #[]
    finally:
      adapter.close
      provider.uninstall

class Provider extends rpc.Provider:
  connected/List? := null
  constructor: super
  capabilities -> List: return [api.CAP-SCAN | api.CAP-GATT-CENTRAL, 60_000_000, 512, 517, 2]
  create-session client/int -> rpc.Session: throw "GATT_UNSUPPORTED_SERVICE_OPERATION"
  create-scan client/int arguments/List -> rpc.Session: return Scan this client
  create-connection client/int arguments/List -> rpc.Session:
    connected = [arguments[0], arguments[1]]
    return Connection this client

class Scan extends rpc.Session:
  sent_/bool := false
  constructor provider/rpc.Provider client/int: super provider client
  invoke index/int arguments/List -> any:
    if index == api.SCAN-NEXT:
      if sent_: return null
      sent_ = true
      return [0, 4, IDENTIFIER.copy, #[2, 9, 0x54], -40]
    if index == api.SCAN-STOP: return [0, 0, 0]
    return super index arguments

class Connection extends rpc.Session:
  constructor provider/rpc.Provider client/int: super provider client
  is-central -> bool: return true
  invoke index/int arguments/List -> any:
    if index == api.CENTRAL-READY: return [IDENTIFIER.copy, 4, 23]
    if index == api.CENTRAL-STOP: return null
    if index == api.LINK-INFO: return [0, 1, 1, 27, 27, 24, 0, 400, IDENTIFIER.copy, 4, null, null]
    return super index arguments

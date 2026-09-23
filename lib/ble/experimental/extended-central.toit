// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import io

import .central as central
import .connection as connection
import .hci as hci
import .advertising-updates as advertising-updates

/**
Owns central links established through extended HCI commands on the LE 1M PHY.

Requires a freshly initialized controller supporting extended advertising and
  central connections. Call $configure before construction. Legacy advertising,
  scanning and initiating commands must not be used in this controller lifetime.
  Peripheral accept remains unavailable until bounded advertising is integrated.

Uses the ordinary link owner, receive task, credit pools and connection cleanup.
  Controller privacy is not enabled: addresses are explicit public/random on-air
  addresses, including host-selected RPAs. This separately reachable class lets
  ordinary providers discard extended command encoding and event decoding.
*/
class Central extends central.Central:
  constructor controller/hci.Controller --acl-length/int=27 --acl-count/int=1
      --early-acl-timeout/Duration?=null --receive-limit/int=65
      --link-limit/int=1 --acl-quota/int?=null --accept-parameter-requests/bool=false:
    super controller --acl-length=acl-length --acl-count=acl-count
        --early-acl-timeout=early-acl-timeout
        --receive-limit=receive-limit
        --link-limit=link-limit
        --acl-quota=acl-quota
        --accept-parameter-requests=accept-parameter-requests

  connection-opcode -> int: return 0x2043

  encode-connection address/ByteArray --address-type/int --own-address-type/int -> ByteArray:
    return create-parameters address --address-type=address-type --own-address-type=own-address-type

  decode-connection-event packet/ByteArray --role/int -> connection.Completion?:
    return decode-completion packet --role=role

  accept advertisement/ByteArray --scan-response/ByteArray=#[] --interval/int=160
      --timeout/Duration=(Duration --s=30) --local-random-address/ByteArray?=null
      --updates/advertising-updates.Changes?=null -> central.Link:
    throw "HCI_EXTENDED_ADVERTISING_REQUIRED"

/** Enables enhanced connection events before assigning the controller's owner. */
configure controller/hci.Controller info/hci.Capabilities -> none:
  if info.le-features[1] & 0x10 == 0: throw "HCI_EXTENDED_ADVERTISING_UNSUPPORTED"
  if info.commands[37] & 0x80 == 0: throw "HCI_EXTENDED_INITIATING_UNSUPPORTED"
  controller.command hci.LE-SET-EVENT-MASK #[0x5f, 0x0a, 0, 0, 0, 0, 0, 0]

/** Encodes one explicit peer and the LE 1M initiating PHY (Core 6.3, 7.8.66). */
create-parameters address/ByteArray --address-type/int --own-address-type/int=0 -> ByteArray:
  if address.size != 6 or not 0 <= address-type <= 1 or not 0 <= own-address-type <= 1:
    throw "INVALID_ARGUMENT"
  bytes := ByteArray 26
  bytes[1] = own-address-type
  bytes[2] = address-type
  bytes.replace 3 address
  bytes[9] = 1
  io.LITTLE-ENDIAN.put-uint16 bytes 10 0x10
  io.LITTLE-ENDIAN.put-uint16 bytes 12 0x10
  io.LITTLE-ENDIAN.put-uint16 bytes 14 24
  io.LITTLE-ENDIAN.put-uint16 bytes 16 40
  io.LITTLE-ENDIAN.put-uint16 bytes 20 400
  return bytes

/** Decodes Enhanced Connection Complete v1 for explicit on-air addresses. */
decode-completion packet/ByteArray --role/int=0 -> connection.Completion?:
  if role != 0 and role != 1: throw "INVALID_ARGUMENT"
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[3] != 0x0a: return null
  if packet.size != 34: throw "HCI_MALFORMED_CONNECTION_EVENT"
  status := packet[4]
  if status != 0: return connection.Completion status 0 0 #[] 0 0 0
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  if handle > 0x0eff or packet[8] > 1: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[7] != role: throw "HCI_UNEXPECTED_CONNECTION_ROLE"
  // These fields must be zero without controller address resolution. Reject
  // unexpected identity/RPA state rather than pass the wrong address to SMP.
  12.repeat:
    if packet[it + 15] != 0: throw "HCI_UNEXPECTED_CONTROLLER_PRIVACY"
  interval := io.LITTLE-ENDIAN.uint16 packet 27
  latency := io.LITTLE-ENDIAN.uint16 packet 29
  timeout := io.LITTLE-ENDIAN.uint16 packet 31
  if not 6 <= interval <= 3200 or not 0 <= latency <= 499 or
      not 10 <= timeout <= 3200 or timeout * 4 <= (latency + 1) * interval:
    throw "HCI_MALFORMED_CONNECTION_EVENT"
  return connection.Completion status handle packet[8] packet[9..15].copy interval latency timeout --role=role

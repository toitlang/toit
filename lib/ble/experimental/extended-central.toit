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
  if address.size != 6 or not 0 <= address-type <= 3 or not 0 <= own-address-type <= 1:
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

/** Decodes Enhanced Connection Complete v1, with or without controller address resolution. */
decode-completion packet/ByteArray --role/int=0 -> connection.Completion?:
  return connection.decode-enhanced-completion packet --role=role

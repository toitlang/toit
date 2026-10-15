// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .hci as hci

/**
Legacy advertising reports and their AD data.

$reports-do decodes one LE Advertising Report event into $Report objects
  that own their bytes, so a scan loop can keep a report after the next
  receive. $advertises-service and $has-limited-discoverable-flags inspect
  the AD data without allocating decoded structures; $Report wraps them for
  a single report. The scanning libraries and the scanning provider build
  their discovery loops on these.
*/

/** A legacy advertising report backed by managed packet storage. */
class Report:
  event-type/int
  address-type/int
  address/ByteArray
  data/ByteArray
  rssi/int?

  constructor .event-type .address-type .address .data .rssi:

  /** Checks advertised service UUID lists using $uuid in little-endian order. */
  has-service uuid/ByteArray -> bool:
    return advertises-service data uuid

  /** Reports the Limited Discoverable flag in this report's own AD data. */
  limited-discoverable -> bool: return has-limited-discoverable-flags data

/**
Checks the Limited Discoverable flag without allocating decoded AD objects.

Missing, duplicate, empty or truncated Flags fields do not qualify. Trailing
  malformed AD data invalidates the report; a zero-length terminator ends it.
  Scan responses are not associated with previous advertisements here.
*/
has-limited-discoverable-flags data/ByteArray -> bool:
  offset := 0
  seen := false
  limited := false
  while offset < data.size:
    length := data[offset]
    if length == 0: return limited
    end := offset + 1 + length
    if end > data.size: return false
    if data[offset + 1] == 1:
      if seen or length < 2: return false
      seen = true
      limited = data[offset + 2] & 1 != 0
    offset = end
  return limited

/**
Checks complete and incomplete service UUID lists in advertising $data.

Accepts a 2-, 4-, or 16-byte little-endian $uuid, including Bluetooth base-UUID
  equivalence. Malformed advertising data returns false; it is untrusted peer
  data and does not justify closing the controller. Service-data and solicitation
  fields are not service UUID lists.
*/
advertises-service data/ByteArray uuid/ByteArray -> bool:
  // AD types and the service UUID list formats: CSS v15, Part A, section 1.1.
  target := expanded-uuid_ uuid
  short-target/bool? := uuid.size != 16 ? true : null
  offset := 0
  found := false
  while offset < data.size:
    length := data[offset]
    if length == 0: return found
    end := offset + 1 + length
    if end > data.size: return false
    type := data[offset + 1]
    width := 0
    if type == 2 or type == 3: width = 2
    else if type == 4 or type == 5: width = 4
    else if type == 6 or type == 7: width = 16
    if width != 0:
      if (length - 1) % width != 0: return false
      if width != 16 and short-target == null:
        short-target = equal-range_ target 0 BLUETOOTH-BASE-UUID_ 0 12
      compatible := width == 16 or (short-target and (width == 4 or (target[14] == 0 and target[15] == 0)))
      pos := offset + 2
      while pos < end:
        // Native whole-array comparison is faster for UUID128. Short lists
        // compare in place, avoiding a slice and expansion for each entry.
        if compatible and (width == 16
            ? data[pos..pos + width] == target
            : (equal-range_ data pos target 12 width)):
          found = true
        pos += width
    offset = end
  return found

BLUETOOTH-BASE-UUID_ ::= #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 0, 0, 0, 0]

// Compares directly in the managed packet; no per-entry slice or expansion.
equal-range_ a/ByteArray a-offset/int b/ByteArray b-offset/int size/int -> bool:
  size.repeat:
    if a[a-offset + it] != b[b-offset + it]: return false
  return true

expanded-uuid_ uuid/ByteArray -> ByteArray:
  if uuid.size == 16: return uuid
  if uuid.size != 2 and uuid.size != 4: throw "INVALID_ARGUMENT"
  result := BLUETOOTH-BASE-UUID_.copy
  result.replace 12 uuid
  return result

/**
Decodes a legacy LE Advertising Report event through a scoped $report block.

Validates the whole event before delivering reports. Returns false for other
  events. Address bytes retain HCI's least-significant-octet-first order; address
  type is part of the identity. Unknown event/address types are preserved.
  Unavailable or reserved RSSI values become null. Retained reports keep their
  managed bytes alive and are not invalidated by the next receive.
*/
reports-do packet/ByteArray [report] -> bool:
  // Event format: Core 6.3, Vol 4 Part E, sections 5.2 and 7.7.65.2.
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return false
  if packet.size < 4: throw "HCI_MALFORMED_ADVERTISING_REPORT"
  if packet[3] != 2: return false
  if packet.size < 5 or not 1 <= packet[4] <= 25:
    throw "HCI_MALFORMED_ADVERTISING_REPORT"
  offset := 5
  packet[4].repeat:
    if offset + 10 > packet.size:
      throw "HCI_MALFORMED_ADVERTISING_REPORT"
    length := packet[offset + 8]
    if length > 31 or offset + 10 + length > packet.size:
      throw "HCI_MALFORMED_ADVERTISING_REPORT"
    offset += 10 + length
  if offset != packet.size: throw "HCI_MALFORMED_ADVERTISING_REPORT"
  offset = 5
  packet[4].repeat:
    length := packet[offset + 8]
    raw-rssi := packet[offset + 9 + length]
    signed-rssi := raw-rssi < 128 ? raw-rssi : raw-rssi - 256
    rssi := -127 <= signed-rssi <= 20 ? signed-rssi : null
    decoded := Report packet[offset] packet[offset + 1]
        packet[offset + 2..offset + 8]
        packet[offset + 9..offset + 9 + length]
        rssi
    report.call decoded
    offset += 10 + length
  return true

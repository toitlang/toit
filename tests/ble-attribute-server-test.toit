// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import expect show *

main:
  database := server.Database
  expect-equals 1 (database.add-service #[0xf0, 0xff])
  expect-equals 3 (database.add-characteristic #[0xf1, 0xff] --read --write --notify --value=#[7, 8])
  uuid := #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  expect-equals 5 (database.add-service uuid)
  expect-equals 7 (database.add-characteristic uuid --write)
  session := database.session
  other := database.session
  expect (catch: database.add-service #[0, 0x18]) == "GATT_DATABASE_SEALED"
  expect-equals #[3, 23, 0] (session.request #[2, 0xff, 0])
  expect-equals #[3, 23, 0] (session.request #[2, 22, 0])
  session.response-sent
  expect-equals #[1, 4, 0, 0, 4] (session.request #[4, 1])
  expect-equals #[1, 4, 0, 0, 1] (session.request #[4, 0, 0, 0xff, 0xff])
  expect-equals #[1, 8, 2, 0, 1] (session.request #[8, 2, 0, 1, 0, 3, 0x28])
  // Mixed service UUID widths require separate pages.
  expect-equals #[0x11, 6, 1, 0, 4, 0, 0xf0, 0xff]
      session.request #[0x10, 1, 0, 0xff, 0xff, 0, 0x28]
  page := session.request #[0x10, 5, 0, 0xff, 0xff, 0, 0x28]
  expect-equals #[0x11, 20, 5, 0, 7, 0] page[0..6]
  expect-equals uuid page[6..]
  expect-equals #[1, 0x10, 8, 0, 0x0a]
      session.request #[0x10, 8, 0, 0xff, 0xff, 0, 0x28]
  expect-equals #[1, 0x10, 1, 0, 0x10]
      session.request #[0x10, 1, 0, 0xff, 0xff, 3, 0x28]
  expect-equals #[7, 1, 0, 4, 0]
      session.request #[6, 1, 0, 0xff, 0xff, 0, 0x28, 0xf0, 0xff]
  expect-equals #[1, 6, 1, 0, 0x0a]
      session.request #[6, 1, 0, 0xff, 0xff, 0, 0x28, 0xf1, 0xff]
  expect-equals #[9, 7, 2, 0, 0x1a, 3, 0, 0xf1, 0xff]
      session.request #[8, 1, 0, 0xff, 0xff, 3, 0x28]
  page = session.request #[8, 6, 0, 0xff, 0xff, 3, 0x28]
  expect-equals #[9, 21, 6, 0, 8, 7, 0] page[0..7]
  expect-equals uuid page[7..]
  // Find Information ignores value permissions and packs whole UUID entries.
  expect-equals #[5, 1, 1, 0, 0, 0x28, 2, 0, 3, 0x28, 3, 0, 0xf1, 0xff, 4, 0, 2, 0x29, 5, 0, 0, 0x28]
      session.request #[4, 1, 0, 0xff, 0xff]
  page = session.request #[4, 7, 0, 7, 0]
  expect-equals #[5, 2, 7, 0] page[0..4]
  expect-equals uuid page[4..]
  expect-equals #[0x0b, 7, 8] (session.request #[0x0a, 3, 0])
  expect-equals #[1, 0x0a, 7, 0, 2] (session.request #[0x0a, 7, 0])
  expect-equals #[1, 0x0a, 8, 0, 1] (session.request #[0x0a, 8, 0])
  expect-equals #[1, 0x12, 1, 0, 3] (session.request #[0x12, 1, 0, 0])
  request := #[0x12, 3, 0, 42]
  expect-equals #[0x13] (session.request request)
  request[3] = 99
  expect-equals #[0x0b, 42] (other.request #[0x0a, 3, 0])
  // CCCD writes affect one session only and validate the supported bits.
  expect-equals #[0x13] (session.request #[0x12, 4, 0, 1, 0])
  expect (session.subscribed 3)
  expect (not (other.subscribed 3))
  expect-equals #[0x0b, 1, 0] (session.request #[0x0a, 4, 0])
  expect-equals #[0x0b, 0, 0] (other.request #[0x0a, 4, 0])
  expect-equals #[1, 0x12, 4, 0, 0x13] (session.request #[0x12, 4, 0, 2, 0])
  expect-equals #[1, 0x12, 4, 0, 0x0d] (session.request #[0x12, 4, 0, 1])
  expect-equals #[0x13] (session.request #[0x12, 4, 0, 0, 0])
  expect (not (session.subscribed 3))
  expect-equals #[0x13] (session.request #[0x12, 4, 0, 0, 0])
  expect-equals null (session.request #[0x52, 3, 0, 99])
  expect-equals #[0x0b, 42] (session.request #[0x0a, 3, 0])
  // Read Multiple Variable Length refuses the invalid handle; an undefined
  // request opcode is not supported.
  expect-equals #[1, 0x20, 0, 0, 1] (session.request #[0x20, 3, 0, 0, 0])
  expect-equals #[1, 0x26, 0, 0, 6] (session.request #[0x26, 3, 0])
  // Bluetooth-base 128-bit types match their 16-bit equivalent.
  expect-equals #[9, 7, 2, 0, 0x1a, 3, 0, 0xf1, 0xff]
      session.request #[8, 1, 0, 4, 0, 0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 3, 0x28, 0, 0]
  full := server.Database
  64.repeat: full.add-service #[0, 0x18]
  expect (catch: full.add-service #[0, 0x18]) == "GATT_DATABASE_FULL"
  // A larger database on request, up to 512 attributes.
  large := server.Database --attribute-limit=300
  300.repeat: large.add-service #[0, 0x18]
  expect (catch: large.add-service #[0, 0x18]) == "GATT_DATABASE_FULL"
  expect (catch: server.Database --attribute-limit=513) == "INVALID_ARGUMENT"
  // Read By Type stops before an unreadable match, then errors when that
  // match becomes the first requested attribute on the next page.
  permissions := server.Database
  mutable-uuid := #[0xf2, 0xff]
  mutable-value := #[17]
  permissions.add-service #[0xf0, 0xff]
  permissions.add-characteristic mutable-uuid --read --value=mutable-value
  permissions.add-characteristic mutable-uuid --write
  permissions.add-characteristic mutable-uuid --read --value=#[18]
  mutable-uuid[0] = 0
  mutable-value[0] = 0
  reader := permissions.session
  expect-equals #[9, 3, 3, 0, 17]
      reader.request #[8, 1, 0, 0xff, 0xff, 0xf2, 0xff]
  expect-equals #[1, 8, 5, 0, 2]
      reader.request #[8, 4, 0, 0xff, 0xff, 0xf2, 0xff]
  oversized := ByteArray 24 --initial=0
  oversized[0] = 0x12
  expect-equals #[1, 0x12, 0, 0, 4] (reader.request oversized)
  expect-equals #[0x0b, 17] (reader.request #[0x0a, 3, 0])
  test-local-values
  test-queued-writes
  test-truncated-type-pages
  test-characteristic-groups

test-characteristic-groups:
  database := server.Database
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --notify
  database.add-characteristic #[0xf2, 0xff] --read
  database.add-service #[0xf3, 0xff]
  database.add-characteristic #[0xf4, 0xff] --read --notify
  session := database.session
  // Declaration2 groups value3 and CCCD4, stopping before declaration5.
  // Group end may extend beyond the request's ending handle (Vol3 PartF3.4.3.4).
  expect-equals #[7, 2, 0, 4, 0]
      session.request #[6, 2, 0, 2, 0, 3, 0x28, 0x12, 3, 0, 0xf1, 0xff]
  // Declaration5 ends at value6, before the next service at7.
  expect-equals #[7, 5, 0, 6, 0]
      session.request #[6, 1, 0, 0xff, 0xff, 3, 0x28, 2, 6, 0, 0xf2, 0xff]
  // The final characteristic includes its final descriptor at10.
  expect-equals #[7, 8, 0, 10, 0]
      session.request #[6, 1, 0, 0xff, 0xff, 3, 0x28, 0x12, 9, 0, 0xf4, 0xff]
  // Service groups still include all their characteristics.
  expect-equals #[7, 1, 0, 6, 0]
      session.request #[6, 1, 0, 1, 0, 0, 0x28, 0xf0, 0xff]
  // Characteristic grouping is not supported by Read By Group Type.
  expect-equals #[1, 0x10, 1, 0, 0x10]
      session.request #[0x10, 1, 0, 0xff, 0xff, 3, 0x28]
  session.close

test-truncated-type-pages --dynamic/bool=false:
  // At MTU 517 two truncated 253-byte values fit, but original lengths
  // must still match (Core 6.3 Vol 3 Part F 3.4.4.1).
  [253, 254, 255, 512].do: | first-size/int |
    [253, 254, 255, 512].do: | second-size/int |
      database := server.Database --mtu-limit=517 --value-limit=512
      database.add-service #[0xf0, 0xff]
      first := ByteArray first-size --initial=17
      second := ByteArray second-size --initial=34
      database.add-characteristic #[0xf1, 0xff] --read --value=first --dynamic-read=dynamic
      database.add-characteristic #[0xf1, 0xff] --read --value=second --dynamic-read=dynamic
      session := database.session
      expect-equals #[3, 5, 2] (session.request #[2, 5, 2])
      session.response-sent
      page := session.request #[8, 1, 0, 0xff, 0xff, 0xf1, 0xff]: | request/server.ReadRequest |
        request.reply (request.handle == 3 ? first : second)
      expected := #[9, 255, 3, 0] + first[..253]
      if first-size == second-size: expected += #[5, 0] + second[..253]
      expect-equals expected page
      next := session.request #[8, 4, 0, 0xff, 0xff, 0xf1, 0xff]: | request/server.ReadRequest |
        request.reply second
      expect-equals (#[9, 255, 5, 0] + second[..253]) next
      session.close
  if not dynamic: test-truncated-type-pages --dynamic

test-queued-writes:
  database := server.Database
  database.add-service #[0xf0, 0xff]
  database.add-characteristic #[0xf1, 0xff] --read --write --value=#[10, 11]
  database.add-characteristic #[0xf2, 0xff] --read --write --value=#[20]
  session := database.session
  other := database.session
  prepare := #[0x16, 3, 0, 0, 0, 42]
  expect-equals #[0x17, 3, 0, 0, 0, 42] (session.request prepare)
  prepare[5] = 99
  expect-equals #[0x0b, 10, 11] (session.request #[0x0a, 3, 0])
  expect-equals #[0x19] (other.request #[0x18, 1])
  expect-equals #[0x19] (session.request #[0x18, 0])
  expect-equals #[10, 11] (database.value 3)
  session.request #[0x16, 3, 0, 0, 0, 42]
  session.request #[0x16, 3, 0, 1, 0, 43]
  expect-equals #[0x19] (session.request #[0x18, 1])
  writes := []
  session.writes-do: | handle/int value/ByteArray | writes.add [handle, value]
  expect-equals [[3, #[42, 43]]] writes
  session.writes-do: unreachable
  writes[0][1][0] = 0
  expect-equals #[42, 43] (database.value 3)
  // An error in the second attribute leaves the first attribute unchanged.
  session.request #[0x16, 3, 0, 0, 0, 99]
  expect-equals #[0x17, 5, 0, 2, 0, 44] (session.request #[0x16, 5, 0, 2, 0, 44])
  expect-equals #[1, 0x18, 5, 0, 7] (session.request #[0x18, 1])
  expect-equals #[42, 43] (database.value 3)
  expect-equals #[0x19] (session.request #[0x18, 1])
  expect-equals #[20] (database.value 5)
  8.repeat:
    expect-equals #[0x17, 3, 0, 0, 0, 7] (session.request #[0x16, 3, 0, 0, 0, 7])
  expect-equals #[1, 0x16, 3, 0, 9] (session.request #[0x16, 3, 0, 0, 0, 8])
  expect-equals #[0x19] (session.request #[0x18, 1])
  expect-equals #[7] (database.value 3)
  large := ByteArray 23 --initial=1
  large.replace 0 #[0x16, 3, 0, 0, 0]
  session.request large
  session.request #[0x16, 3, 0, 18, 0, 2, 3, 4]
  expect-equals #[1, 0x18, 3, 0, 0x0d] (session.request #[0x18, 1])
  expect-equals #[7] (database.value 3)
  session.request #[0x16, 3, 0, 0, 0, 55]
  session.close
  expect-equals #[0x19] (database.session.request #[0x18, 1])
  expect-equals #[7] (database.value 3)

test-local-values:
  defaults := server.Database.with-defaults --name="Toit"
  baseline := defaults.session
  expect-equals #[0x11, 6, 1, 0, 5, 0, 0, 0x18, 6, 0, 9, 0, 1, 0x18]
      baseline.request #[0x10, 1, 0, 0xff, 0xff, 0, 0x28]
  expect-equals #[0x0b, 0x54, 0x6f, 0x69, 0x74] (baseline.request #[0x0a, 3, 0])
  expect-equals #[0x0b, 0, 0] (baseline.request #[0x0a, 5, 0])
  database := server.Database.with-defaults
  database.add-service #[0xf0, 0xff]
  handle := database.add-characteristic #[0xf1, 0xff] --read --notify
  expect-equals 12 handle
  session := database.session
  other := database.session
  expect-equals null (session.notification handle)
  expect-equals #[0x13] (session.request #[0x12, 13, 0, 1, 0])
  input := #[42, 43]
  database.set-value handle input
  input[0] = 0
  snapshot := database.value handle
  snapshot[0] = 1
  expect-equals #[0x0b, 42, 43] (session.request #[0x0a, 12, 0])
  notification := session.notification handle
  expect-equals #[0x1b, 12, 0, 42, 43] notification
  expect-equals null (other.notification handle)
  database.set-value handle #[99]
  expect-equals #[0x1b, 12, 0, 42, 43] notification
  expect-equals #[0x1b, 12, 0, 99] (session.notification handle)
  expect (catch: database.set-value 8 #[0]) == "GATT_INVALID_VALUE_HANDLE"
  expect (catch: database.set-value 10 #[0]) == "GATT_INVALID_VALUE_HANDLE"
  expect (catch: database.set-value handle (ByteArray 21)) == "INVALID_ARGUMENT"
  expect-equals #[99] (database.value handle)
  expect (catch: session.notification 3) == "GATT_NOT_NOTIFIABLE"
  session.close
  session.close
  expect (not (session.subscribed handle))
  expect (catch: session.notification handle) == "ATT_SERVER_CLOSED"
  expect (catch: session.request #[0x0a, 12, 0]) == "ATT_SERVER_CLOSED"
  reopened := database.session
  expect-equals null (reopened.notification handle)
  expect-equals #[0x0b, 0, 0] (reopened.request #[0x0a, 13, 0])
  expect-equals #[0x0b, 99] (reopened.request #[0x0a, 12, 0])

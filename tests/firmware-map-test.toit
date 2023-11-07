// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect
import system.firmware
import system.base.firmware show FirmwareServiceProviderBase FirmwareWriter

main:
  test-simple-mapping
  test-map

test-simple-mapping:
  bytes := ByteArray 19: it
  mapping := firmware.FirmwareMapping_ bytes
  test-mapping bytes mapping

test-map:
  // TODO(kasper): Find a way to check the behavior
  // if there is no service installed without running
  // into issues where the current process caches
  // the service client.

  service := FirmwareServiceProvider
  service.install

  block-called := false
  firmware.map: | mapping/firmware.FirmwareMapping? |
    block-called = true
    expect.expect-null mapping
  expect.expect block-called

  service.content = ByteArray 19: it
  block-called = false
  firmware.map: | mapping/firmware.FirmwareMapping? |
    block-called = true
    test-mapping service.content mapping
  expect.expect block-called

  test-map-within-bounds 0 0 service.content
  test-map-within-bounds 0 1 service.content
  test-map-within-bounds 0 19 service.content
  test-map-within-bounds 7 17 service.content
  test-map-out-of-bounds 20 20
  test-map-out-of-bounds 20 21
  test-map-out-of-bounds 4 3

  service.uninstall

test-map-within-bounds from/int to/int bytes/ByteArray -> none:
  block-called := false
  try:
    firmware.map --from=from --to=to: | mapping/firmware.FirmwareMapping? |
      block-called = true
      test-mapping bytes[from..to] mapping
  finally:
    expect.expect block-called

test-map-out-of-bounds from/int to/int -> none:
  block-called := false
  try:
    firmware.map --from=from --to=to: | mapping/firmware.FirmwareMapping? |
      block-called = true
      expect.expect-null mapping
  finally:
    expect.expect block-called

test-mapping bytes/ByteArray mapping/firmware.FirmwareMapping:
  expect.expect-equals bytes.size mapping.size
  for i := 0; i < bytes.size; i++:
    for j := i; j < bytes.size; j++:
      section := ByteArray j - i
      mapping.copy i j --into=section
      expect.expect-bytes-equal bytes[i..j] section
      section.size.repeat:
        expect.expect-equals section[it] mapping[it + i]

  expect.expect-null (mapping.copy 0 0 --into=#[])
  expect.expect-throw "OUT_OF_BOUNDS": mapping[-1]
  expect.expect-throw "OUT_OF_BOUNDS": mapping[mapping.size]
  expect.expect-throw "OUT_OF_BOUNDS": mapping[10000]

  buffer := ByteArray mapping.size + 100
  expect.expect-throw "OUT_OF_BOUNDS": mapping.copy -1 0 --into=buffer
  expect.expect-throw "OUT_OF_BOUNDS": mapping.copy 1000 1000 --into=buffer
  expect.expect-throw "OUT_OF_BOUNDS": mapping.copy 0 mapping.size + 1 --into=buffer
  expect.expect-throw "OUT_OF_BOUNDS": mapping.copy 4 3 --into=buffer
  expect.expect-throw "OUT_OF_BOUNDS": mapping.copy 20 7 --into=buffer
  expect.expect-throw "OUT_OF_BOUNDS": mapping.copy 21 -1 --into=buffer

  if bytes.size < 4: return
  split := bytes.size / 2
  test-mapping bytes[..split] mapping[..split]
  test-mapping bytes[split..] mapping[split..]

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  content/ByteArray? := null

  constructor:
    super "system/firmware/test" --major=1 --minor=0

  is-validation-pending -> bool:
    unreachable
  is-rollback-possible -> bool:
    unreachable
  validate -> bool:
    unreachable
  rollback -> none:
    unreachable
  upgrade -> none:
    unreachable
  config-ubjson -> ByteArray:
    unreachable
  config-entry key/string -> any:
    unreachable
  uri -> string?:
    unreachable
  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    unreachable

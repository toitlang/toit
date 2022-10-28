// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect
import system.firmware
import system.base.firmware show FirmwareServiceDefinitionBase FirmwareWriter

main:
  test_simple_mapping
  test_map

test_simple_mapping:
  bytes := ByteArray 19: it
  mapping := firmware.FirmwareMapping_ bytes
  test_mapping bytes mapping

test_map:
  // TODO(kasper): Find a way to check the behavior
  // if there is no service installed without running
  // into issues where the current process caches
  // the service client.

  service := FirmwareServiceDefinition
  service.install

  block_called := false
  firmware.map: | mapping/firmware.FirmwareMapping? |
    block_called = true
    expect.expect_null mapping
  expect.expect block_called

  service.content = ByteArray 19: it
  block_called = false
  firmware.map: | mapping/firmware.FirmwareMapping? |
    block_called = true
    test_mapping service.content mapping
  expect.expect block_called

  test_map_within_bounds 0 0 service.content
  test_map_within_bounds 0 1 service.content
  test_map_within_bounds 0 19 service.content
  test_map_within_bounds 7 17 service.content
  test_map_out_of_bounds 20 20
  test_map_out_of_bounds 20 21
  test_map_out_of_bounds 4 3

  service.uninstall

test_map_within_bounds from/int to/int bytes/ByteArray -> none:
  block_called := false
  try:
    firmware.map --from=from --to=to: | mapping/firmware.FirmwareMapping? |
      block_called = true
      test_mapping bytes[from..to] mapping
  finally:
    expect.expect block_called

test_map_out_of_bounds from/int to/int -> none:
  block_called := false
  try:
    firmware.map --from=from --to=to: | mapping/firmware.FirmwareMapping? |
      block_called = true
      expect.expect_null mapping
  finally:
    expect.expect block_called

test_mapping bytes/ByteArray mapping/firmware.FirmwareMapping:
  expect.expect_equals bytes.size mapping.size
  for i := 0; i < bytes.size; i++:
    for j := i; j < bytes.size; j++:
      section := ByteArray j - i
      mapping.copy i j --into=section
      expect.expect_bytes_equal bytes[i..j] section
      section.size.repeat:
        expect.expect_equals section[it] mapping[it + i]

  expect.expect_null (mapping.copy 0 0 --into=#[])
  expect.expect_throw "OUT_OF_BOUNDS": mapping[-1]
  expect.expect_throw "OUT_OF_BOUNDS": mapping[mapping.size]
  expect.expect_throw "OUT_OF_BOUNDS": mapping[10000]

  buffer := ByteArray mapping.size + 100
  expect.expect_throw "OUT_OF_BOUNDS": mapping.copy -1 0 --into=buffer
  // expect.expect_throw "OUT_OF_BOUNDS": mapping.copy 1000 1000 --into=buffer
  expect.expect_throw "OUT_OF_BOUNDS": mapping.copy 0 mapping.size + 1 --into=buffer

  // TODO(kasper): Test reversed arguments (to > from).


  if bytes.size < 4: return
  split := bytes.size / 2
  test_mapping bytes[..split] mapping[..split]
  test_mapping bytes[split..] mapping[split..]

class FirmwareServiceDefinition extends FirmwareServiceDefinitionBase:
  content/ByteArray? := null

  constructor:
    super "system/firmware/test" --major=1 --minor=0

  is_validation_pending -> bool:
    unreachable
  is_rollback_possible -> bool:
    unreachable
  validate -> bool:
    unreachable
  rollback -> none:
    unreachable
  upgrade -> none:
    unreachable
  config_ubjson -> ByteArray:
    unreachable
  config_entry key/string -> any:
    unreachable
  firmware_writer_open client/int from/int to/int -> FirmwareWriter:
    unreachable

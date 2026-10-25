// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import system.base.firmware show FirmwareServiceProviderBase FirmwareWriter

main:
  test-valid
  test-configured

test-valid:
  expect (system.is-valid-hostname_ "toit")
  expect (system.is-valid-hostname_ "a")
  expect (system.is-valid-hostname_ "Brave-Otter-42")
  expect (system.is-valid-hostname_ ("a" * 32))
  expect-not (system.is-valid-hostname_ "")
  expect-not (system.is-valid-hostname_ ("a" * 33))
  expect-not (system.is-valid-hostname_ "-toit")
  expect-not (system.is-valid-hostname_ "toit-")
  expect-not (system.is-valid-hostname_ "my_device")
  expect-not (system.is-valid-hostname_ "my.device")
  expect-not (system.is-valid-hostname_ "my device")
  expect-not (system.is-valid-hostname_ "🐱")
  expect-not (system.is-valid-hostname_ "nö")

test-configured:
  service := FirmwareServiceProvider
  service.install

  test-config service --hostname="jag-name" --expected="jag-name"
  test-config service --hostname=null --expected=null
  test-config service --hostname="bad_name" --expected=null
  test-config service --hostname=42 --expected=null

  service.uninstall

test-config service/FirmwareServiceProvider --hostname/any --expected/string? -> none:
  service.config = hostname == null ? {:} : {"hostname": hostname}
  expect-equals expected system.configured-hostname_

  // The bucket overrides the firmware config.
  system.set-configured-hostname_ "app-name"
  expect-equals "app-name" system.configured-hostname_

  expect-throw "INVALID_ARGUMENT": system.set-configured-hostname_ "bad_name"
  expect-throw "INVALID_ARGUMENT": system.set-configured-hostname_ ("a" * 33)
  expect-equals "app-name" system.configured-hostname_

  // Removing the override falls back to the firmware config.
  system.set-configured-hostname_ null
  expect-equals expected system.configured-hostname_

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  config/Map := {:}

  constructor:
    super "system/firmware/test" --major=1 --minor=0

  config-entry key/string -> any:
    return config.get key

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
  content -> ByteArray?:
    unreachable
  uri -> string?:
    unreachable
  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    unreachable

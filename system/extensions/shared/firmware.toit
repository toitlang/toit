// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import system.base.firmware show FirmwareServiceProviderBase

import encoding.ubjson

/**
Shared provider behavior for embedded firmware services.

Platform providers supply validation, rollback, upgrade, URI, and writer
mechanics. Embedded configuration and firmware-content fallback have the
same contract on ESP32 and EC618.
*/
abstract class EmbeddedFirmwareServiceProviderBase
    extends FirmwareServiceProviderBase:
  config_/Map ::= {:}

  constructor name/string:
    catch: config_ = ubjson.decode firmware-embedded-config_
    super name --major=0 --minor=1

  config-ubjson -> ByteArray:
    // The service boundary currently requires a disposable copy.
    return firmware-embedded-config_.copy

  config-entry key/string -> any:
    return config_.get key

  content -> ByteArray?:
    // Let the common firmware API map the running platform image.
    return null

firmware-embedded-config_ -> any:
  #primitive.programs-registry.config

// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Example of an Ethernet provider container.

Providers should be started at boot.
*/

import .olimex-poe

main:
  provider := OlimexPoeProvider
  provider.install

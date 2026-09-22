// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-local-command-provider as command

main: run Provider

run provider/Provider:
  provider.install
  try:
    provider.uninstall --wait
    print "LOCAL_DESCRIPTOR_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends command.Provider:
  constructor: super
  local-random-address -> ByteArray?: return #[4, 0x30, 0x23, 0xf2, 0x3a, 0xc8]

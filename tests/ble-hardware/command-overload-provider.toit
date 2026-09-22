// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .fixtures.vhci-command-overload-provider as fixture

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    print "COMMAND_OVERLOAD_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends fixture.Provider:
  constructor: super --receive-flow
  local-random-address -> ByteArray?: return null

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .command-native-overload-provider as fixture

main:
  provider := fixture.Provider --authenticated
  provider.install
  try:
    provider.uninstall --wait
    print "COMMAND_OVERLOAD_PROVIDER COMPLETE"
  finally:
    provider.uninstall

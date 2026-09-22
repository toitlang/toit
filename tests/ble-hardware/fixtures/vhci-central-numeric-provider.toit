// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-central-provider as fixture
import .vhci-central-pairing-provider as pairing

main: fixture.run (pairing.Provider --numeric)

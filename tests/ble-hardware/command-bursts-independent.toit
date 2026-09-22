// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .fixtures.service-command-bursts as fixture

// Public hci3 fixture identity, used by the independent Bumble host.
main: fixture.run --peer=#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]

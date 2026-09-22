// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .fixtures.vhci-cccd-persistence as fixture

main:
  fixture.run --no-resume --storage-path="toit.test/cccd-persist-v1"
      --peer-address=#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]

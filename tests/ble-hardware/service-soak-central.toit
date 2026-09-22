// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.linux
import .fixtures.hci-echo as fixture

main args/List:
  if args.size != 3: throw "Usage: service-soak-central ADAPTER COUNT LOG_EVERY"
  fixture.run (linux.LinuxTransport (int.parse args[0]))
      --count=(int.parse args[1])
      --log-every=(int.parse args[2])
      --peer-address=#[0x14, 0x30, 0x23, 0xf2, 0x3a, 0xc8]

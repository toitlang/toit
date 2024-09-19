// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.modules.dns

main:
  network := net.open
  task:: exit 0
  dns.dns-lookup "localhost" --network=network

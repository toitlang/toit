// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .udp as udp
import net
import net.udp as net

main:
  net.IpAddress.parse
    net.open.address.stringify

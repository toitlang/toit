// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
A simple client for an Ethernet network.

Requires the Ethernet provider to be installed.
*/

import net
import net.ethernet

main:
  network := ethernet.open
  use network
  network.close

use network/net.Client:
  // Do something with the client.

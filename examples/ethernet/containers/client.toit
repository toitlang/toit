// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
A simple client for an Ethernet network.

Requires the Ethernet service to be installed.
*/

import net.ethernet

main:
  network := ethernet.open
  // Use the network.
  network.close

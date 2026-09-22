// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.linux
import encoding.hex
import .bounded-connecting-peer as fixture

main args/List:
  if not 2 <= args.size <= 3:
    throw "Usage: bounded-linux-peer.toit <adapter index> <public owner address> [winning]"
  winning := args.size == 3
  if winning and args[2] != "winning": throw "INVALID_ARGUMENT"
  peer := (hex.decode (args[1].replace --all ":" "")).reverse
  fixture.run-with-transport (linux.LinuxTransport (int.parse args[0])) peer
      --canceled-first=winning

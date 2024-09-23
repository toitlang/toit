// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.modules.tcp
import system
import system show platform

// https://github.com/toitware/toit/issues/3

expect name [code]:
  expect-equals
    name
    catch code

main:
  // Port 47 is reserved/unassigned.
  network := net.open
  socket := tcp.TcpSocket network
  if platform == system.PLATFORM-WINDOWS:
    expect "No connection could be made because the target machine actively refused it.\r\n": socket.connect "localhost" 47
  else:
    expect "Connection refused": socket.connect "localhost" 47

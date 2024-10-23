// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

main:
  expected-hostname/string := ?
  if system.platform == system.PLATFORM-WINDOWS:
    expected-hostname = pipe.backticks "hostname"
  else if system.platform == system.PLATFORM-LINUX:
    // On newer versions of `hostnamectl` we could also use "hostnamectl hostname",
    // but our buildbot doesn't support that yet.
    output := pipe.backticks "hostnamectl" "status"
    // Something like:
    //  Static hostname: red
    //        Icon name: computer-desktop
    //          Chassis: desktop 🖥
    // ...
    line := (output.split "\n")[0]
    expected-hostname = (line.split ":")[1]
  else if system.platform == system.PLATFORM-MACOS:
    expected-hostname = pipe.backticks "hostname" "-s"
  else:
    unreachable

  expected-hostname = expected-hostname.trim
  expect-equals expected-hostname system.hostname

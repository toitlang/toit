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
    expected-hostname = pipe.backticks "hostnamectl" "hostname"
  else:
    expected-hostname = pipe.backticks "hostname" "-s"
  expected-hostname = expected-hostname.trim

  expect-equals expected-hostname system.hostname

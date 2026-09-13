// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

/**
Exercises every common GPIO primitive through the pin resource.

PAD34 is otherwise unused on the test rig. Its internal pull-up gives the
  input read a deterministic level without another board.
*/

main:
  pin := gpio.Pin 34 --input --pull-up
  sleep --ms=10
  if pin.get != 1: throw "PAD34 pull-up did not read high"

  pin.set-pull --off
  pin.configure --output --value=0
  pin.set 1
  pin.set-open-drain true
  pin.set 0
  pin.set 1
  pin.set-open-drain false
  pin.close

  closed-error := catch: pin.set 0
  if not closed-error: throw "closed pin still accepted set"

  print "gpio-resource-ec618: PASS resource-backed config/get/set/open-drain/pull and closed-pin rejection"

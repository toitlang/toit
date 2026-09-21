// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import gpio.adc as adc
import .session
import .wiring

/** Executes operations on the testee, returning observations without a verdict. */
class Testee:
  pins_/Map := {:}
  analog_/adc.Adc? := null

  serve session/Session:
    try:
      while true:
        request := session.receive
        op := request[0]
        if op == "end": return
        session.send (execute_ request)
    finally:
      pins_.values.do: it.close
      if analog_: analog_.close

  execute_ request/List -> any:
    op := request[0]
    if op == "echo": return request[1]
    if op == "pin":
      pin := request[1]
      if not GPIO-LINKS.contains pin: throw "Unsafe testee pin: $pin"
      old := pins_.get pin
      pins_.remove pin
      if old: old.close
      pins_[pin] = request[2] == "input"
          ? (gpio.Pin pin --input)
          : (gpio.Pin pin --output --value=0)
      return null
    if op == "set":
      pins_[request[1]].set request[2]
      return null
    if op == "open-drain":
      pins_[request[1]].set-open-drain true
      return null
    if op == "levels":
      result := {:}
      pins_.do: | pin resource | result[pin] = resource.get
      return result
    if op == "read": return pins_[request[1]].get
    if op == "wait":
      pins_[request[1]].wait-for request[2]
      return pins_[request[1]].get
    if op == "pull":
      pin := pins_[request[1]]
      if request[2] == 0: pin.set-pull --off
      else if request[2] == 1: pin.set-pull --up
      else: pin.set-pull --down
      return null
    if op == "adc":
      if not analog_: analog_ = adc.Adc H2-ADC
      return analog_.get --samples=128
    throw "Unknown testee operation: $op"

call session/Session request/List -> any:
  session.send request
  return session.receive

run-case session/Session name/string [tester]:
  session.run-case name:
    if IS-TESTEE:
      (Testee).serve session
    else:
      tester.call
      session.send ["end"]

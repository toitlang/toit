// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .session
import .wiring
import ..paired.pwm as pwm-tests
import ..paired.uart as uart-tests
import ..paired.gpio as gpio-tests
import ..paired.pixel-strip as pixel-tests

main args/List:
  selection := args.is-empty or args[0] == "" ? "all" : args[0]
  expect (["all", "pwm", "pwm-reverse", "uart", "gpio", "pixels", "pixels-uart", "pixels-rmt"].contains selection)
  session := Session
  try:
    if selection == "pwm-reverse":
      // Synchronize with the runner's normal startup order before swapping.
      session.run-case "Reverse PWM roles": null
      session.is-testee = not session.is-testee
    if selection == "all" or selection == "pwm" or selection == "pwm-reverse":
      pwm-tests.run session PWM-PIN PWM-SECOND-PIN
    if selection == "all" or selection == "uart":
      uart-tests.run session UART-READY
    if selection == "all" or selection == "gpio":
      gpio-tests.run session GPIO-PIN
    if selection == "all" or selection.starts-with "pixels":
      backends := selection == "all" or selection == "pixels-uart" ? ["uart"] :
          (selection == "pixels-rmt" ? ["rmt"] : ["rmt", "uart"])
      pixel-tests.run session UART-READY --backends=backends
    session.finish
  finally:
    session.close

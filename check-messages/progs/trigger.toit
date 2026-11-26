// Copyright (C) 2026 Toit contributors.
// Triggers failing ESP-IDF checks and error logs (no hardware needed, runs
// in QEMU), so that the console shows their messages.

import gpio
import gpio.pwm
import uart
import system

attempt name/string [block]:
  e := catch: block.call
  print "TRIGGER $name: $e"

main:
  stats := system.process-stats --gc
  print "TRIGGER-START system-free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]"
  // GPIO 34 is input only: gpio_set_level's GPIO_CHECK (a "%s" argument)
  // and gpio_config's ESP_LOGE.
  attempt "output-on-input-only": gpio.Pin 34 --output --value=1
  attempt "output-on-input-only-2": gpio.Pin 35 --output
  // LEDC cannot reach this frequency: ESP_LOGE with numeric arguments.
  attempt "pwm-frequency":
    generator := pwm.Pwm --frequency=40_000_000
    generator.start 18
  attempt "pwm-frequency-low":
    generator := pwm.Pwm --frequency=1
    generator.start 19
  attempt "uart-baud": uart.Port --tx=17 --rx=16 --baud-rate=0
  print "TRIGGER-DONE"

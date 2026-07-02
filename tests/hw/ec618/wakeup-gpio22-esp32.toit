// Copyright (C) 2026 Toit contributors.

/**
ESP32 half of the EC618 GPIO22 (PAD42) wakeup-pad test.

IO13 is wired to EC618 board pin 9 = GPIO22 = PAD42 = a WAKEUP_PAD. (It is
also the BMP280 power switch; the sensor must be UNPLUGGED for this test so
the net is a clean point-to-point wire.)

The EC618 firmware arms the wakeup pads (both edges, internal pull-down) at
deep-sleep entry. This helper holds IO13 low while the EC618 hibernates,
then toggles it to make edges that should wake the EC618 (wake src=PAD).

Run it (board2) just before/at the same time as triggering the EC618
hibernate on board1; it waits long enough for the EC618 to be asleep before
pulsing.
*/
import gpio

PAD42-NET ::= 13  // ESP32 IO13 -> EC618 board pin 9 (GPIO22 / PAD42).

main:
  pin := gpio.Pin PAD42-NET --output --value=0
  print "wakeup-gpio22-esp32: IO13 low; waiting 60s for the EC618 to hibernate"
  sleep --ms=60_000
  print "wakeup-gpio22-esp32: pulsing IO13 (6x) to wake the EC618"
  6.repeat:
    pin.set 1
    sleep --ms=400
    pin.set 0
    sleep --ms=400
  // Leave the line low (matches the armed pull-down resting state).
  print "wakeup-gpio22-esp32: done pulsing"
  sleep --ms=5_000
  pin.close

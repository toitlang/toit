import pulse_counter
import gpio

main:
  task::
    pin2 := gpio.Pin 5 --output
    while true:
      pin2.set 1
      sleep --ms=20
      pin2.set 0
      sleep --ms=20

  pin := gpio.Pin 18
  unit := pulse_counter.Unit
  channel := unit.add_channel pin
  unit.clear
  i := 0
  while true:
    print unit.value
    sleep --ms=500
    i++

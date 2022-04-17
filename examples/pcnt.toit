import pulse_counter
import gpio

main:
  pin2 := gpio.Pin 5 --output
  task::
    while true:
      pin2.set 1
      sleep --ms=20
      pin2.set 0
      sleep --ms=20

  pin := gpio.Pin 18
  unit := pulse_counter.Unit
  channel := unit.add_channel pin
  unit.clear
  5.repeat:
    print unit.value
    sleep --ms=500
  print unit.value
  channel.close
  sleep --ms=500
  print unit.value
  channel = unit.add_channel pin
  5.repeat:
    print unit.value
    sleep --ms=500

  channel2 := unit.add_channel (gpio.Pin 26)
  i := 0
  while true:
    print unit.value
    sleep --ms=20
    i++
    if i == 20:
      print "closing channel1"
      channel.close

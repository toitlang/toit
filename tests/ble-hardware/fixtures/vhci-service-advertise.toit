// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.service.advertising-provider as advertising
import ble.experimental.service.provider as rpc
import system.containers
import .service-advertise as application

main arguments: run arguments

run arguments --abrupt/bool=false:
  with-timeout --ms=70_000:
    if arguments is Map:
      failure := catch:
        with-timeout --ms=20_000: application.main
      if failure != DEADLINE-EXCEEDED-ERROR: throw (failure or "EARLY_APPLICATION_EXIT")
    else:
      provider := Provider
      provider.install
      try:
        2.repeat: | cycle/int |
          child := containers.start containers.current {"application": true}
          try:
            forced := abrupt and cycle == 0
            if forced:
              with-timeout --ms=3_000:
                while provider.radios.is-empty or (provider.radios.last as Radio).replies != 1:
                  sleep --ms=1
              sleep --ms=15_000
              active/Radio := provider.radios.last
              if active.closed or active.disables != 0 or active.replies != 1 or provider.session.is-released:
                throw "ADVERTISING_ENDED_BEFORE_FORCED_STOP"
              if child.stop != 0: throw "ADVERTISING_APPLICATION_STOP_FAILED"
            else:
              if child.wait != 0: throw "ADVERTISING_APPLICATION_FAILED"
            with-timeout --ms=5_000:
              while not provider.session or not provider.session.is-released: sleep --ms=1
            if provider.radios.size != cycle + 1: throw "WRONG_RADIO_COUNT"
            radio/Radio := provider.radios.last
            if not radio.closed or radio.enables != 1 or radio.disables != 1 or radio.replies != 2:
              throw "ADVERTISING_CLEANUP_INCOMPLETE"
            print "SERVICE_ADVERTISE CLIENT cycle=$cycle exit=0 forced=$forced enables=1 disables=1 replies=2 closed=true"
          finally:
            child.close
          sleep --ms=8_000
        print "SERVICE_ADVERTISE COMPLETE clients=2"
      finally:
        critical-do --no-respect-deadline: provider.uninstall

class Provider extends advertising.Provider:
  radios/List := []
  session/rpc.Session? := null
  constructor: super
  open-transport -> Radio:
    radio := Radio
    radios.add radio
    return radio
  create-advertising client/int arguments/List -> rpc.Session:
    session = super client arguments
    return session

class Radio extends esp32.Esp32Transport:
  enables/int := 0
  disables/int := 0
  replies/int := 0
  closed/bool := false
  constructor: super
  send-if packet/ByteArray [allowed] -> bool:
    sent := super packet allowed
    if sent and packet.size == 5 and packet[..4] == #[1, 10, 32, 1]:
      if packet[4] == 1: enables++
      else: disables++
    return sent
  receive -> ByteArray:
    packet := super
    if packet.size == 7 and packet[..2] == #[4, 14] and packet[4..] == #[10, 32, 0]: replies++
    return packet
  close -> none:
    if closed: return
    super
    closed = true

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import monitor
import pulse-counter
import rmt
import uart
import .session

/** Tests long bursts and consecutive LED-style writes on the testee TX wire. */
run session/Session ready-pin/int:
  [[115200, 8, uart.Port.PARITY-DISABLED],
      [921600, 7, uart.Port.PARITY-EVEN],
      [921600, 8, uart.Port.PARITY-DISABLED]].do: | config |
    session.run-case "UART duplex and framing $config":
      window session ready-pin
          --transmit=: | ready/gpio.Pin |
            duplex session config ready
          --observe=: | ready/gpio.Pin |
            duplex session config ready
  [115200, 921600, 2_500_000].do: | baud |
    [true, false].do: | pause |
      session.run-case "UART continuity baud=$baud injected-pause=$pause":
        size := 32768
        filter := min 12000 (3_000_000_000 / baud)
        wire-ms := size * 10_000 / baud
        window session ready-pin
            --transmit=: | ready/gpio.Pin |
              port := uart.Port --tx=session.tx --rx=null --baud-rate=baud
              try:
                data := ByteArray size --initial=0
                await-trigger ready
                if pause:
                  port.out.write data[..size / 2] --flush
                  sleep --ms=20
                  port.out.write data[size / 2..] --flush
                else:
                  port.out.write data --flush
                ready.wait-for 0
              finally:
                port.close
            --observe=: | ready/gpio.Pin |
              counter := pulse-counter.Unit session.rx --glitch-filter-ns=filter
              try:
                ready.set 1
                sleep --ms=(wire-ms + 300)
                count := counter.value
                print "UART filter=$(filter)ns idle-edges=$count"
                if pause: expect count >= 2
                else: expect-equals 1 count
              finally:
                counter.close
  [true, false].do: | pause |
    session.run-case "UART LED timing injected-pause=$pause":
      repetitions := 90
      window session ready-pin
          --transmit=: | ready/gpio.Pin |
            port := uart.Port --tx=session.tx --rx=null --baud-rate=2_500_000 --data-bits=7
            try:
              data := ByteArray 1024 --initial=0xaa
              data[1022] = 0xff
              data[1023] = 0
              await-trigger ready
              repetitions.repeat: | i |
                port.out.write data
                if pause and i == repetitions / 2:
                  port.out.flush
                  sleep --ms=1
              port.out.flush
              ready.wait-for 0
            finally:
              port.close
          --observe=: | ready/gpio.Pin |
            input := rmt.In session.rx --resolution=4_000_000 --memory-blocks=2
            try:
              input.start-reading --min-ns=1000 --max-ns=5_000_000
              ready.set 1
              signals := input.wait-for-data
              valid := signals.size == 2 * repetitions
              signals.do: | level period ns |
                if level == 1 and ns >= 3500: valid = false
              expect-equals (not pause) valid
            finally:
              input.close

/** Temporarily lends the control UART to a test, using one GPIO for readiness. */
window session/Session ready-pin/int [--transmit] [--observe]:
  ready := session.is-testee
      ? (gpio.Pin ready-pin --input --output --open-drain --pull-up --value=0)
      : (gpio.Pin ready-pin --input --pull-up)
  try:
    if session.is-testee:
      expect-equals "switch UART" session.receive
      session.send "prepared"
      session.port.close
      transmit.call ready
      session.reopen
      session.send "restored"
    else:
      session.send "switch UART"
      expect-equals "prepared" session.receive
      session.port.close
      // Wait until the testee has initialized its peripheral. Pin mux changes
      // during initialization must not be mistaken for measured waveforms.
      ready.wait-for 1
      ready.configure --input --output --open-drain --pull-up --value=0
      sleep --ms=1
      try:
        observe.call ready
      finally:
        // Open the receiver before allowing the testee to restore framing.
        session.reopen
        ready.set 0
      expect-equals "restored" session.receive
  finally:
    ready.close

// Concurrent reading is essential: neither side may rely on fitting the entire
// transfer into the receive buffer before it starts draining it.
duplex session/Session config/List ready/gpio.Pin:
  port := uart.Port --rx=session.rx --tx=session.tx
      --baud-rate=config[0]
      --data-bits=config[1]
      --parity=config[2]
  writer/Task? := null
  done := monitor.Latch
  try:
    mask := (1 << config[1]) - 1
    seed := session.is-testee ? 17 : 93
    peer-seed := session.is-testee ? 93 : 17
    size := 32769
    if session.is-testee:
      await-trigger ready
      port.out.write-byte 0x55
      port.out.flush
    else:
      ready.set 1
      expect-equals 0x55 port.in.read-byte
    writer = task::
      error := catch:
        // Stream bounded chunks so the fixture needs no external RAM.
        offset := 0
        while offset < size:
          count := min (offset == 0 ? 127 : 1024) (size - offset)
          port.out.write (ByteArray count: ((offset + it) * 37 + seed) & mask)
          offset += count
        port.out.flush
      done.set error
    offset := 0
    while offset < size:
      count := min 1024 (size - offset)
      observed := port.in.read-bytes count
      expect-equals (ByteArray count: ((offset + it) * 37 + peer-seed) & mask) observed
      offset += count
    error := done.get
    if error: throw error
    expect-equals 0 port.errors
    if session.is-testee: ready.wait-for 0
  finally:
    if writer: writer.cancel
    port.close

/** Announces that the peripheral is initialized, then waits for capture start. */
await-trigger ready/gpio.Pin:
  ready.set 1
  ready.wait-for 0
  ready.wait-for 1

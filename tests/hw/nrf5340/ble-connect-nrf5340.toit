// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import expect show *
import monitor
import system

// This random-static address must be absent from the test environment.
ABSENT ::= #[1, 0xc2, 0x47, 0x73, 0x19, 0xaa, 0x55]

main:
  expect-equals system.PLATFORM-ZEPHYR system.platform
  4.repeat: |cycle|
    print "BLE connection cycle=$cycle starting"
    adapter := ble.Adapter
    central := adapter.central
    [#[], #[4, 0, 0, 0, 0, 0, 0], #[0, 1]].do: |address|
      expect-equals "INVALID_ARGUMENT" (catch: central.connect address)
    expect-equals "UNIMPLEMENTED" (catch: central.connect ABSENT --secure)
    4.repeat:
      error := catch:
        with-timeout --ms=80: central.connect ABSENT
      expect-equals DEADLINE-EXCEEDED-ERROR error
    // A cancelled constructor must release its native connection immediately.
    // Each following connect and scan must be able to reuse the controller.
    central.scan --duration=(Duration --ms=0): unreachable
    peripheral := adapter.peripheral
    peripheral.start-advertise (ble.Advertisement --name="toit-nrf-probe")
    peer := null
    with-timeout --ms=10_000:
      while not peer:
        central.scan --duration=(Duration --s=1): |device|
          if device.data.name != "toit-esp-peer": continue.scan
          expect device.is-connectable
          peer = device.identifier
          expect-equals "ALREADY_IN_USE" (catch: central.connect peer)
    peripheral.close
    print "BLE connection cycle=$cycle found peer=$peer"
    8.repeat: |iteration|
      print "BLE connection cycle=$cycle iteration=$iteration connecting"
      device := with-timeout --ms=5000: central.connect peer
      print "BLE connection cycle=$cycle iteration=$iteration connected"
      expect device.mtu >= 23
      expect-equals "ALREADY_IN_USE" (catch: central.connect peer)
      with-timeout --ms=5000: device.close --force=(iteration % 2 == 0)
      device.close
    if cycle == 0:
      before := Time.monotonic-us
      error := catch:
        with-timeout --ms=5000: central.connect ABSENT
      expect-equals "BLE connection failed" error
      expect Time.monotonic-us - before >= 2_500_000
    // Adapter close must drain an established connection before HCI shutdown.
    device := with-timeout --ms=5000: central.connect peer
    with-timeout --ms=5000: adapter.close
    expect device.is-closed
    print "BLE connection cycle=$cycle PASS"
  adapter := ble.Adapter
  central := adapter.central
  pending := monitor.Latch
  task:: pending.set (catch: central.connect ABSENT)
  sleep --ms=30
  with-timeout --ms=5000: adapter.close
  expect-equals "BLE connection failed" (with-timeout --ms=1000: pending.get)
  print "BLE adapter close during connection PASS"
  // The peer observes a disconnect when process teardown drains this link.
  adapter = ble.Adapter
  peer := null
  with-timeout --ms=10_000:
    while not peer:
      adapter.central.scan --duration=(Duration --s=1): |device|
        if device.data.name == "toit-esp-peer": peer = device.identifier
  with-timeout --ms=5000: adapter.central.connect peer
  print "NRF5340 BLE CONNECTION PASS: cancellation, 32 connections, timeout and 4 adapter reopen cycles"

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.power
import system.power-wakeup_ show decode-wakeup-sources

main:
  expect-list-equals [] (decode-wakeup-sources #[])
  // Level GPIO, both-edge GPIO, falling dedicated input, and touch source.
  encoded := #[0, 32, 29, 0, 42, 107, 1, 1, 44, 2, 0, 0]
  sources := decode-wakeup-sources encoded
  expect-equals 4 sources.size
  pin := sources[0] as power.PinWakeup
  expect-list-equals [32] pin.pins
  expect-equals power.WAKE-LEVEL pin.trigger
  expect-equals true pin.wake-high
  expect-equals false pin.all-low
  expect-equals false pin.pull-up
  expect-equals true pin.pull-down
  both := sources[1] as power.PinWakeup
  expect-list-equals [42] both.pins
  expect-equals power.WAKE-EDGE both.trigger
  expect-equals null both.wake-high
  expect-equals true both.pull-up
  input := sources[2] as power.InputWakeup
  expect-equals 1 input.input
  expect-equals power.WAKE-EDGE input.trigger
  expect-equals false input.wake-high
  expect-equals true input.pull-down
  expect (sources[3] is power.TouchWakeup)

  // Mutating a returned list must not alias another snapshot or the input.
  pin.pins.clear
  fresh := (decode-wakeup-sources encoded)[0] as power.PinWakeup
  expect-list-equals [32] fresh.pins

  // Original ESP32 ALL_LOW is one condition over a group, not two ANY_LOW sources.
  group := (decode-wakeup-sources #[0, 32, 152, 0, 33, 152])[0] as power.PinWakeup
  expect-list-equals [32, 33] group.pins
  expect-equals true group.all-low
  expect-equals false group.wake-high
  expect-equals power.WAKE-LEVEL group.trigger
  expect-throw "INVALID_ARGUMENT": decode-wakeup-sources #[0, 32]
  expect-throw "INVALID_ARGUMENT": decode-wakeup-sources #[3, 0, 0]

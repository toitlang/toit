// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2c
import spi
import system

import .test
import .variants

expect-oom [block]:
  exception := catch block
  expect
      exception == "ALLOCATION_FAILED"
          or exception == "MALLOC_FAILED"
          or exception == "OUT_OF_MEMORY"

main:
  run-test: test

test:
  variant := Variant.CURRENT
  data := variant.unconnected-pin1
  clock := variant.unconnected-pin2
  select := variant.unconnected-pin3

  // These deliberately impossible native allocations fail on every primitive
  // attempt. If an attempt retains pins, a peripheral, or another native
  // resource, the following retry reports ALREADY_IN_USE instead of OOM.
  expect-oom:
    i2c.Target
        --sda=data
        --scl=clock
        --address=0x42
        --send-buffer-size=(1 << 30)
        --receive-buffer-size=64
  target := i2c.Target
      --sda=data
      --scl=clock
      --address=0x42
  target.close

  // Register targets are not supported on the original ESP32.
  if system.architecture != system.ARCHITECTURE-ESP32:
    expect-oom:
      i2c.RegisterTarget
          --sda=data
          --scl=clock
          --address=0x42
          --receive-buffer-size=(1 << 30)
    register-target := i2c.RegisterTarget
        --sda=data
        --scl=clock
        --address=0x42
    register-target.close

  expect-oom:
    spi.Target
        --mosi=data
        --clock=clock
        --cs=select
        --max-transfer-size=(1 << 30)
  spi-target := spi.Target
      --mosi=data
      --clock=clock
      --cs=select
      --max-transfer-size=64
  spi-target.close

  expect-oom:
    spi.BufferTarget
        --mosi=data
        --clock=clock
        --cs=select
        --buffer-size=4
        --receive-queue-depth=(1 << 29)
  buffer-target := spi.BufferTarget
      --mosi=data
      --clock=clock
      --cs=select
      --buffer-size=4
      --receive-queue-depth=2
  buffer-target.close

  test-i2c-controller-oom data clock
  system.process-stats --gc
  test-spi-controller-oom data clock select

native-failure-size -> int:
  // The source is stored in PSRAM on ESP32-S3, while peripheral transfers
  // require internal DMA memory. Classic ESP32 has enough memory for the
  // source, but not for a second allocation of the same size.
  if system.architecture == system.ARCHITECTURE-ESP32: return 70_000
  return 1_000_000

test-i2c-controller-oom sda/int scl/int:
  bus := i2c.Bus --sda=sda --scl=scl
  device := bus.device 0x42
  buffer := ByteArray native-failure-size
  expect-oom: device.read-into buffer
  device.close
  bus.close

  // Prove that both the driver handle and pins remain reusable.
  retry := i2c.Bus --sda=sda --scl=scl
  retry-device := retry.device 0x42
  retry-device.close
  retry.close

test-spi-controller-oom mosi/int clock/int cs/int:
  bus := spi.Bus --mosi=mosi --clock=clock
  device := bus.device --cs=cs --frequency=100_000
  buffer := ByteArray native-failure-size
  expect-oom: device.write buffer
  device.close
  bus.close

  // Prove that both the driver handle and pins remain reusable.
  retry := spi.Bus --mosi=mosi --clock=clock
  retry-device := retry.device --cs=cs --frequency=100_000
  retry-device.close
  retry.close

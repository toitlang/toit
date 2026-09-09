// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import i2c
import io

import .framed-control show FramedChannel
import .uart-rig as rig
/**
EC618 I2C long-transfer + clock-stretch validation (device under test).

Validates the paths the bmp280/torture tests cannot reach:

1. TX FIFO REFILL: a 25-byte register-pair stream write (reg,val,reg,val,
   ... — the BMP280 ACKs arbitrary pair streams) exceeds the 16-deep TX
   FIFO, so the engine's refill interrupt must feed the tail. Verified by
   reading the registers back.
2. CLOCK STRETCHING: the ESP32 holds the SCL net low (open-drain, like a
   real stretching slave) in the middle of a long transfer. The master
   must pause and complete correctly after the release — same data, no
   errors, elapsed time >= the hold.
3. CANCELLATION + LATE RELEASE: a transfer is cancelled while the ESP32
   holds SCL low. The helper releases SCL after the cancelled task has
   unwound, and the same device must transfer successfully again.

Stretched operations are SINGLE-LEG transfers (one MasterReceive or one
  MasterTransmit) at 51 kHz (the arbitrary-TPR path), so the hold lands
  deterministically inside the transfer. A stretch landing exactly in the
  microsecond gap between the two legs of a chained write-then-read would
  abort that transfer cleanly (bounded chain wait) — a documented
  limitation, not exercised here.

*/

ADDRESS ::= 0x76
REG-CALIBRATION ::= 0x88
REG-CONFIG ::= 0xf5
REG-CONTROL-MEAS ::= 0xf4

failures := []

main:
  control-owner := rig.ec618-uart 2 115200
  control := FramedChannel control-owner.port
  control.send "HELLO"
  control.expect "READY" --timeout-ms=120_000
  control.send "P 1"
  control.expect "P 1" --timeout-ms=10_000

  bus := Ec618.i2c1  // SDA=PAD23, SCL=PAD24.

  // --- 1. TX refill: 25-byte pair-stream write, read back. ------------------
  fast := bus.device ADDRESS --frequency=100_000
  // 12 (register, value) pairs, all targeting config — the BMP280 ACKs
  // arbitrary pair streams and the LAST value wins. 24 bytes > the 16-deep
  // TX FIFO, so the tail must come through the refill interrupt.
  pairs := ByteArray 24
  12.repeat: | i |
    pairs[2 * i] = REG-CONFIG
    pairs[2 * i + 1] = (i == 11) ? 0b000_100_00 : (i & 0xff)
  fast.write pairs
  config := (fast.registers.read-u8 REG-CONFIG)
  print "i2c-stretch-ec618: 25-byte pair-stream write, config readback 0x$(%02x config)"
  check (config == 0b000_100_00) "tx-refill-25B-write"
  fast.close  // One Device per address at a time.

  // --- 2. Stretch during a long single-leg READ. -----------------------------
  // 51 kHz is the real floor (the TPR divisor fields are 8-bit:
  // functional_clk / (2*255); slower requests are rejected), and 512 bytes
  // is the hardware's longest single command (9-bit length field). A
  // 512-byte auto-increment read takes ~90 ms — the 150 ms SCL hold,
  // started 30 ms in, lands deterministically inside the transfer.
  LONG ::= 512
  HOLD ::= 150
  slow := bus.device ADDRESS --frequency=51_000
  slow.write #[REG-CALIBRATION]             // Set the register pointer.
  reference := slow.read 24
  baseline-us := elapsed-us:
    slow.write #[REG-CALIBRATION]
    slow.read LONG
  print "i2c-stretch-ec618: 51 kHz baseline pointer+$(LONG)B read: $(baseline-us / 1000) ms"

  control.send "H 30 $HOLD"                 // Squat SCL at +30 ms for 150 ms.
  control.expect "H ok" --timeout-ms=10_000
  stretched/ByteArray? := null
  stretched-us := elapsed-us:
    slow.write #[REG-CALIBRATION]
    stretched = slow.read LONG
  print "i2c-stretch-ec618: stretched read: $(stretched-us / 1000) ms (hold $HOLD ms)"
  check (stretched[..24] == reference) "stretch-read-data-intact"
  check (stretched-us >= baseline-us + (HOLD - 50) * 1000) "stretch-read-paused"
  check (stretched-us < baseline-us + 3 * HOLD * 1000) "stretch-read-resumed"

  // --- 3. Stretch during a long single-leg WRITE. ----------------------------
  // 256 (register, value) pairs, all targeting config: ~90 ms on the
  // wire; the hold lands mid-write; the LAST value must stick.
  long-pairs := ByteArray LONG
  (LONG / 2).repeat: | i |
    long-pairs[2 * i] = REG-CONFIG
    long-pairs[2 * i + 1] = (i == LONG / 2 - 1) ? 0b000_100_00 : (i & 0xff)
  control.send "H 30 $HOLD"
  control.expect "H ok" --timeout-ms=10_000
  write-us := elapsed-us:
    slow.write long-pairs
  config2 := (slow.registers.read-u8 REG-CONFIG)
  print "i2c-stretch-ec618: stretched $(LONG)B write: $(write-us / 1000) ms, config readback 0x$(%02x config2)"
  check (config2 == 0b000_100_00) "stretch-write-data-intact"
  check (write-us >= baseline-us + (HOLD - 50) * 1000) "stretch-write-paused"

  // --- 4. Cancel while the peripheral is stalled, then recover. -------------
  // Set the pointer before holding SCL so the timed operation has one async
  // hardware leg. The helper asserts SCL low in the middle of that leg, and
  // the deadline then cancels the stalled operation. It releases the line
  // well after the cancelled task has unwound; any resulting stale event must
  // be harmless.
  slow.write #[REG-CALIBRATION]
  control.send "H 20 300"
  control.expect "H ok" --timeout-ms=10_000
  cancellation := catch:
    with-timeout --ms=100:
      slow.read LONG
  check (cancellation == "DEADLINE_EXCEEDED") "cancel-held-read-deadline"

  sleep --ms=350
  slow.write #[REG-CALIBRATION]
  recovered := slow.read 24
  check (recovered == reference) "recover-after-cancel-and-late-release"

  slow.close
  bus.close
  control.send "P 0"
  control.expect "P 0" --timeout-ms=10_000
  control.send "Q"
  control.expect "BYE" --timeout-ms=10_000
  control-owner.close

  if not failures.is-empty:
    print "i2c-stretch-ec618: FAIL $failures"
    throw "I2C stretch test failed: $failures"
  print "i2c-stretch-ec618: PASS refill + stretch + cancellation recovery"

check ok/bool label/string -> none:
  print "i2c-stretch-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label

elapsed-us [block] -> int:
  duration := Duration.of block
  return duration.in-us

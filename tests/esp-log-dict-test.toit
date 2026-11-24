// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.sha256 as crypto
import encoding.hex
import expect show *
import io
import io show LITTLE-ENDIAN

import ..tools.esp-log-dict

main:
  test-crc
  test-printf
  test-format-kinds
  test-elf-index
  test-decode
  test-captured

test-crc:
  // The check value of CRC-16/CCITT-FALSE.
  expect-equals 0x29b1 (crc16 "123456789".to-byte-array)

w32 value/int -> int: return value & 0xffff_ffff
f64 value/float -> int: return value.bits

test-printf:
  expect-equals "x=-1 y=4294967295" (format-printf "x=%d y=%u" [w32 -1, w32 -1])
  expect-equals "[   42|42   |00042|+42| 42]" (format-printf "[%5d|%-5d|%05d|%+d|% d]" [42, 42, 42, 42, 42])
  expect-equals "ff FF 0xff 000000ff 0" (format-printf "%x %X %#x %08x %#x" [255, 255, 255, 255, 0])
  expect-equals "17 017" (format-printf "%o %#o" [15, 15])
  expect-equals "-5 -1 1" (format-printf "%ld %hhd %hu" [w32 -5, 0xff, 0x10001])
  expect-equals "-9000000000 18446744073709551615 ffffffffffffffff"
      (format-printf "%lld %llu %llx" [-9000000000, -1, -1])
  expect-equals "[abc|ab|       abc|abc       |(null)]"
      (format-printf "[%s|%.2s|%10s|%-10s|%s]" ["abc", "abc", "abc", "abc", null])
  expect-equals "A 0x3ffb0010 100%" (format-printf "%c %p 100%%" ['A', 0x3ffb0010])
  expect-equals "[   7] [7   ]" (format-printf "[%*d] [%-*d]" [4, 7, 4, 7])
  expect-equals "[  ab]" (format-printf "[%*.*s]" [4, 2, "abcd"])
  expect-equals "0042 " (format-printf "%.4d %.0d" [42, 0])
  expect-equals "3.141590 3.14 -0.50" (format-printf "%f %.2f %.2f" [f64 3.14159, f64 3.14159, f64 -0.5])
  expect-equals "1.234568e+04 1.2E-05" (format-printf "%e %.1E" [f64 12345.678, f64 0.0000123])
  expect-equals "0.0001234 1.23457e+08 100 1e+06 0.5"
      (format-printf "%g %g %g %g %g" [f64 0.0001234, f64 123456789.0, f64 100.0, f64 1000000.0, f64 0.5])
  expect-equals "inf -inf nan" (format-printf "%f %f %f" [f64 float.INFINITY, f64 -float.INFINITY, f64 float.NAN])
  // Missing arguments and a pointer printed with %s.
  expect-equals "1 ? ?" (format-printf "%d %d %s" [1])
  expect-equals "<string at 0x3f400010>" (format-printf "%s" [0x3f400010])
  // PRIu32 and friends are plain length modifiers.
  expect-equals "7 8" (format-printf "%lu %zu" [7, 8])

test-format-kinds:
  expect-equals [] (format-kinds "no arguments, 100%%")
  expect-equals [KIND-W32, KIND-STR, KIND-W64, KIND-W64, KIND-W32]
      (format-kinds "%d %s %lld %f %p")
  expect-equals [KIND-W32, KIND-W32, KIND-STR] (format-kinds "%*.*s")

/** A record of the .esp_log_dict section as the device's macros emit it. */
record-bytes --level/int --flags/int --kinds/List --file/string --line/int --format/string -> ByteArray:
  buffer := io.Buffer
  header := ByteArray 12
  kind-bits := 0
  kinds.size.repeat: kind-bits |= kinds[it] << (2 * it)
  LITTLE-ENDIAN.put-uint32 header 0 RECORD-MAGIC
  LITTLE-ENDIAN.put-uint32 header 4 (level | flags << 8 | kinds.size << 16)
  LITTLE-ENDIAN.put-uint32 header 8 kind-bits
  buffer.write header
  buffer.write "$file\0$line\0$format\0"
  while buffer.size % 4 != 0: buffer.write-byte 0
  return buffer.bytes

/**
A minimal 32-bit little-endian ELF file with the sections .shstrtab and
  $SECTION-NAME (with the given $content).
*/
elf-with-section content/ByteArray -> ByteArray:
  names := "\0.shstrtab\0$SECTION-NAME\0".to-byte-array
  header-size := 52
  names-offset := header-size
  content-offset := names-offset + names.size
  section-offset := (content-offset + content.size + 3) & ~3
  elf := ByteArray section-offset + 3 * 40
  elf.replace 0 #[0x7f, 'E', 'L', 'F', 1, 1, 1]
  LITTLE-ENDIAN.put-uint16 elf 0x10 2     // ET_EXEC.
  LITTLE-ENDIAN.put-uint16 elf 0x12 94    // EM_XTENSA.
  LITTLE-ENDIAN.put-uint32 elf 0x20 section-offset
  LITTLE-ENDIAN.put-uint16 elf 0x28 header-size
  LITTLE-ENDIAN.put-uint16 elf 0x2e 40
  LITTLE-ENDIAN.put-uint16 elf 0x30 3
  LITTLE-ENDIAN.put-uint16 elf 0x32 1
  elf.replace names-offset names
  elf.replace content-offset content
  // Section 1: .shstrtab.
  h := section-offset + 40
  LITTLE-ENDIAN.put-uint32 elf h 1
  LITTLE-ENDIAN.put-uint32 elf h + 4 3    // SHT_STRTAB.
  LITTLE-ENDIAN.put-uint32 elf h + 16 names-offset
  LITTLE-ENDIAN.put-uint32 elf h + 20 names.size
  // Section 2: the records (not allocated: no flags).
  h += 40
  LITTLE-ENDIAN.put-uint32 elf h 11
  LITTLE-ENDIAN.put-uint32 elf h + 4 1    // SHT_PROGBITS.
  LITTLE-ENDIAN.put-uint32 elf h + 16 content-offset
  LITTLE-ENDIAN.put-uint32 elf h + 20 content.size
  return elf

sample-records -> ByteArray:
  buffer := io.Buffer
  buffer.write
      record-bytes --level=1 --flags=FLAG-CHECK --kinds=[KIND-STR, KIND-W32]
          --file="/IDF/components/esp_driver_gpio/src/gpio.c"
          --line=91
          --format="GPIO number error: %s (%d)"
  // Padding between records, as the linker may insert.
  buffer.write (ByteArray 4)
  buffer.write
      record-bytes --level=2 --flags=0 --kinds=[KIND-W64, KIND-W32]
          --file="/IDF/components/esp_timer/src/esp_timer.c"
          --line=12
          --format="late by %lld us (%x)"
  // A record whose arguments don't match its format.
  buffer.write
      record-bytes --level=1 --flags=0 --kinds=[KIND-W32]
          --file="main.c"
          --line=3
          --format="%s"
  return buffer.bytes

test-elf-index:
  content := sample-records
  elf := elf-with-section content
  index := Index.from-elf elf
  expect-equals (hex.encode (crypto.sha256 elf)) index.elf-sha256
  expect-equals 8 index.build-id.size
  expect-equals 3 index.records.size
  // 88 bytes of the first record, 4 bytes of padding, 80 bytes of the second.
  expect-equals [0, 92, 172] index.records.keys.sort
  first/Record := index.records[0]
  expect first.is-check
  expect-equals 91 first.line
  expect-equals "gpio.c:91" first.short-location
  expect-equals [KIND-STR, KIND-W32] first.kind-list
  second/Record := index.records[92]
  expect-equals 2 second.level
  expect-equals "late by %lld us (%x)" second.format
  expect-equals 1 index.mismatches.size
  expect-equals "main.c" index.mismatches[0].file

  // The encoded index decodes to the same records.
  decoded := Index.decode index.encode
  expect-equals index.elf-sha256 decoded.elf-sha256
  expect-equals index.records.keys.sort decoded.records.keys.sort
  index.records.do: | id/int record/Record |
    other/Record := decoded.records[id]
    expect-equals record.format other.format
    expect-equals record.file other.file
    expect-equals record.line other.line
    expect-equals record.kinds other.kinds
    expect-equals record.flags other.flags
  expect (index.to-text.contains "00000 E check sw /IDF/components/esp_driver_gpio/src/gpio.c:91")

  expect-throw "Not an ELF file.": Index.from-elf (ByteArray 64)
  empty := elf-with-section #[]
  expect-equals 0 (Index.from-elf empty).records.size

/** A dictionary line as the device prints it, with its checksum. */
device-line prefix/string body/string -> string:
  crc := crc16 body.to-byte-array
  return "$prefix$body $(%04x crc)}"

test-decode:
  elf := elf-with-section sample-records
  index := Index.from-elf elf
  build := index.build-id
  decoder := Decoder index

  line := device-line "E (1234) gpio: " "{D1 $build 00000 \"GPIO_NUM_99\" 00000063"
  expect-equals "E (1234) gpio: gpio.c:91: GPIO number error: GPIO_NUM_99 (99)"
      decoder.decode-line line

  // 64-bit arguments; a warning, which gets no location unless asked for.
  line = device-line "W (5) timer: " "{D1 $build 0005c fffffffffffffc18 0000beef"
  expect-equals "W (5) timer: late by -1000 us (beef)" (decoder.decode-line line)
  expect-equals "W (5) timer: esp_timer.c:12: late by -1000 us (beef)"
      (Decoder index --location).decode-line line

  // Escapes, a cut string, and text around the message.
  line = device-line "noise E (1) gpio: " "{D1 $build 00000 \"a\\x22b\\x5c\"+ 00000001"
  expect-equals "noise E (1) gpio: gpio.c:91: GPIO number error: a\"b\\ (1) [log-dict: string cut]\r"
      decoder.decode-line line + "\r"
  // A NULL string.
  line = device-line "E (1) gpio: " "{D1 $build 00000 - 00000002"
  expect-equals "E (1) gpio: gpio.c:91: GPIO number error: (null) (2)" (decoder.decode-line line)
  // Arguments that did not fit.
  line = device-line "E (1) gpio: " "{D1 $build 00000 \"x\" +"
  expect-equals "E (1) gpio: gpio.c:91: GPIO number error: x (?) [log-dict: arguments cut]"
      (decoder.decode-line line)

  // Ordinary lines and lines with a wrong checksum stay as they are.
  expect-equals "I (1) wifi: {D1 is not a message}" (decoder.decode-line "I (1) wifi: {D1 is not a message}")
  bad := (device-line "E (1) gpio: " "{D1 $build 00000 \"GPIO_NUM_99\" 00000063").replace "99\"" "98\""
  expect-equals bad (decoder.decode-line bad)

  // Another build: not decoded unless forced.
  other := device-line "E (1) gpio: " "{D1 0badc0de 00000 \"GPIO_NUM_1\" 00000001"
  expect-equals "$other [log-dict: build 0badc0de, the index is for $build]" (decoder.decode-line other)
  expect-equals "E (1) gpio: gpio.c:91: GPIO number error: GPIO_NUM_1 (1) [log-dict: build 0badc0de, the index is for $build]"
      (Decoder index --force).decode-line other
  // An unknown message and arguments that don't match.
  unknown := device-line "E (1) x: " "{D1 $build 00004 00000001"
  expect-equals "$unknown [log-dict: no message 00004]" (decoder.decode-line unknown)
  mismatch := device-line "E (1) gpio: " "{D1 $build 00000 00000001 00000002"
  expect-equals "E (1) gpio: gpio.c:91: GPIO number error: <string at 0x1> (2) [log-dict: the arguments do not match the message]"
      decoder.decode-line mismatch

/**
Lines captured in QEMU from a classic-ESP32 firmware with dictionary checks
  and ESP_LOGE (logs/qemu-f2dictall.txt of the check-messages prototype),
  and records copied from that firmware's index.
*/
CAPTURED-SHA256 ::= "286d72354a62dc6349f092e23f55ddf7c245662b9ac886c47e14b2c3adaf4026"

captured-index -> Index:
  records := {:}
  add := : | id level flags kinds file line format |
    bits := 0
    kinds.size.repeat: bits |= kinds[it] << (2 * it)
    records[id] = Record
        --id=id
        --level=level
        --flags=flags
        --arg-count=kinds.size
        --kinds=bits
        --file=file
        --line=line
        --format=format
  add.call 0x014a4 1 FLAG-CHECK [KIND-STR] "/IDF/components/esp_driver_gpio/src/gpio.c" 238 "%s"
  add.call 0x0629c 1 FLAG-CHECK [] "/IDF/components/esp_driver_uart/src/uart.c" 1043 "baud rate unachievable"
  add.call 0x1084c 1 0 [KIND-W32] "/IDF/components/esp_driver_i2c/i2c_common.c" 134 "I2C bus id(%d) has already been acquired"
  add.call 0x13094 1 0 [KIND-W32, KIND-W32, KIND-W32] "/IDF/components/esp_driver_ledc/src/ledc.c" 735 "requested frequency %d and duty resolution %d can not be achieved, try reducing freq_hz or duty_resolution. div_param=%lu"
  return Index CAPTURED-SHA256 records

test-captured:
  decoder := Decoder captured-index
  // Verbatim device output (the checksums come from the device).
  expect-equals "E (3528) gpio: gpio.c:238: GPIO output gpio_num error"
      decoder.decode-line "E (3528) gpio: {D1 286d7235 014a4 \"GPIO output gpio_num error\" 1477}"
  expect-equals "E (4136) uart: uart.c:1043: baud rate unachievable"
      decoder.decode-line "E (4136) uart: {D1 286d7235 0629c 04ed}"
  // Synthetic lines for messages of the same firmware with numeric arguments.
  line := device-line "E (12) i2c.common: " "{D1 286d7235 1084c 00000001"
  expect-equals "E (12) i2c.common: I2C bus id(1) has already been acquired" (decoder.decode-line line)
  line = device-line "E (13) ledc: " "{D1 286d7235 13094 02625a00 00000014 00000400"
  expect-equals "E (13) ledc: requested frequency 40000000 and duty resolution 20 can not be achieved, try reducing freq_hz or duty_resolution. div_param=1024"
      decoder.decode-line line

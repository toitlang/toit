// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.md5
import expect show *
import i2s
import system

interface DataGenerator:
  do [block] -> int
  verify chunk/ByteArray
  verified -> int
  written -> int
  increment-error -> none

/**
A generator that produces a repeating pattern of bytes.

This generator doesn't do any verification.
*/
class FastGenerator implements DataGenerator:
  static create-data:
    data := ByteArray.external 1024
    for i := 0; i < 1024; i++: data[i] = i & 0xff
    return data

  constructor data-size/int:
    if data-size != 16 and data-size != 32:
      throw "INVALID_ARGUMENT"

  // DEBUG DEBUG
  // data_/ByteArray := ByteArray 2048: it & 0xff
  data_/ByteArray := create-data
  offset_/int := 0
  verified_/int := 0
  written/int := 0

  do [block] -> int:
    consumed := block.call data_[offset_..]
    offset_ += consumed
    written += consumed
    if offset_ == data_.size:
      offset_ = 0
    return consumed

  verify chunk/ByteArray:
    // No verification needed.
    verified_ += chunk.size

  verified -> int:
    return verified_

  increment-error:
    // Must not happen.
    expect false

class VerifiableData:
  static DATA-SIZE ::= 1024
  static DATA-SIZE24 ::= 1020

  bits-per-sample/int
  bytes-per-sample/int
  raw/ByteArray
  size/int
  iterations/int := -1

  is-8-bit-esp32/bool
  is-24-bit-esp32/bool
  /**
  In mono mode for 8 and 16 bit samples, the ESP32 swaps every 16-bits.
  */
  is-swapped-16-out/bool
  is-swapped-16-in/bool

  stereo-in/int?
  stereo-out/int?

  constructor .bits-per-sample/int --.stereo-in --.stereo-out:
    is-8-bit-esp32 = bits-per-sample == 8 and system.architecture == system.ARCHITECTURE-ESP32
    is-24-bit-esp32 = bits-per-sample == 24 and system.architecture == system.ARCHITECTURE-ESP32
    is-swapped-16-out = (bits-per-sample == 8 or bits-per-sample == 16) and
        (stereo-out == i2s.Bus.SLOTS-MONO-BOTH or stereo-out == i2s.Bus.SLOTS-MONO-LEFT or
          stereo-out == i2s.Bus.SLOTS-MONO-RIGHT) and
        system.architecture == system.ARCHITECTURE-ESP32
    is-swapped-16-in = (bits-per-sample == 8 or bits-per-sample == 16) and
        (stereo-in == i2s.Bus.SLOTS-MONO-LEFT or stereo-in == i2s.Bus.SLOTS-MONO-RIGHT) and
        system.architecture == system.ARCHITECTURE-ESP32

    if bits-per-sample != 24:
      raw = ByteArray DATA-SIZE: it & 0xff
    else:
      raw = ByteArray DATA-SIZE24: it & 0xff
    size = raw.size

    // Set the repetition counter. This counter doesn't change when the buffer is reused.
    for i := 1; i < raw.size; i += 8:
      raw[i] = i / 8

    if is-swapped-16-out:
      print "swapping 16-bit samples"
      // The ESP32 swaps every 16-bits.
      for i := 0; i < raw.size; i += 4:
        tmp := raw[i]
        raw[i] = raw[i + 2]
        raw[i + 2] = tmp
        tmp = raw[i + 1]
        raw[i + 1] = raw[i + 3]
        raw[i + 3] = tmp

    bytes-per-sample = bits-per-sample / 8
    print "stereo-in: $stereo-in stereo-out: $stereo-out"
    if stereo-out == i2s.Bus.SLOTS-STEREO-LEFT or
        stereo-out == i2s.Bus.SLOTS-STEREO-RIGHT or
        stereo-in == i2s.Bus.SLOTS-MONO-LEFT or
        stereo-in == i2s.Bus.SLOTS-MONO-RIGHT:
      is-left := stereo-out == i2s.Bus.SLOTS-STEREO-LEFT or stereo-in == i2s.Bus.SLOTS-MONO-LEFT
      // Only one channel (slot) is used.
      // We double the output size, so we still have the full input on the other side.
      replacement := ByteArray raw.size * 2
      // Duplicate the samples first.
      for i := 0; i < raw.size; i += bytes-per-sample:
        bytes-per-sample.repeat:
          replacement[i * 2 + it] = raw[i + it]
          replacement[i * 2 + bytes-per-sample + it] = raw[i + it]
      // Replace the unused slot with 0xAA. We should not see those in the output.
      unused-offset := is-left ? bytes-per-sample : 0
      for i := unused-offset; i < replacement.size; i += bytes-per-sample * 2:
        bytes-per-sample.repeat: replacement[i + it] = 0xAA
      raw = replacement
      print "Replacement: $raw[64..64 + 16]"

    if system.architecture == system.ARCHITECTURE-ESP32:
      // We assume that the two boards are the same and that the writer is thus
      // also an ESP32 board.
      if bits-per-sample == 8 or bits-per-sample == 16:
        // The

    if is-8-bit-esp32:
      // The ESP32 only uses the MSB of 16-bit chunks.
      raw = ByteArray (raw.size * 2): it & 1 == 0 ? 0 : raw[it / 2]

    if is-24-bit-esp32:
      // The ESP32 only uses the 24MSB of 32-bit chunks.
      replacement := ByteArray (raw.size / 3) * 4
      target-pos := 0
      for i := 0; i < raw.size; i += 3:
        replacement[target-pos++] = 0
        replacement[target-pos++] = raw[i]
        replacement[target-pos++] = raw[i + 1]
        replacement[target-pos++] = raw[i + 2]
      raw = replacement

    print "Raw: $raw[..24]"

    update-iterations

  // Also verifies some properties when fixing.
  fix-chunk chunk/ByteArray -> ByteArray:
    if is-8-bit-esp32:
      // Drop every second byte.
      target-pos := 0
      for i := 1; i < chunk.size; i += 2:
        chunk[target-pos++] = chunk[i]
      chunk = chunk[..target-pos]
    else if is-24-bit-esp32:
      // Drop every 4th byte.
      target-pos := 0
      for i := 1; i < chunk.size; i += 4:
        chunk[target-pos++] = chunk[i]
        chunk[target-pos++] = chunk[i + 1]
        chunk[target-pos++] = chunk[i + 2]
      chunk = chunk[..target-pos]

    if stereo-out == i2s.Bus.SLOTS-STEREO-LEFT or
        stereo-out == i2s.Bus.SLOTS-STEREO-RIGHT or
        stereo-out == i2s.Bus.SLOTS-MONO-LEFT or
        stereo-out == i2s.Bus.SLOTS-MONO-RIGHT or
        stereo-out == i2s.Bus.SLOTS-MONO-BOTH:

      // The left/right channel was emitted for both channels.
      // We check that they are equal and drop the duplicate.
      for i := 0; i < chunk.size; i += bytes-per-sample * 2:
        // We have two cases:
        // The ESP32 just duplicates the data.
        // Other variants keep the unused channel as 0.
        is-left := stereo-out == i2s.Bus.SLOTS-STEREO-LEFT or stereo-out == i2s.Bus.SLOTS-MONO-LEFT
        target-pos := i / 2
        bytes-per-sample.repeat:
          left := chunk[i + it]
          right := chunk[i + bytes-per-sample + it]
          checked := true
          if stereo-out == i2s.Bus.SLOTS-STEREO-LEFT:
            // The ESP32 duplicates the data.
            checked = right == 0x00 or left == right
          else if stereo-out == i2s.Bus.SLOTS-STEREO-RIGHT:
            // The ESP32 duplicates the data.
            checked = left == 0x00 or left == right
          else if stereo-out == i2s.Bus.SLOTS-MONO-LEFT:
            // The unused channel must be 0.
            checked = right == 0x00
          else if stereo-out == i2s.Bus.SLOTS-MONO-RIGHT:
            // The unused channel must be 0.
            checked = left == 0x00
          else if stereo-out == i2s.Bus.SLOTS-MONO-BOTH:
            // Both channels must be the same.
            checked = left == right

          if checked:
            chunk[target-pos + it] = is-left ? left : right
          else:
            print "Mismatch at $i"
            print chunk[max 0 i - 16..max 0 i - 8]
            print chunk[max 0 i - 8..i]
            print "$chunk[i..min chunk.size i + 8]  <- first byte here"
            print chunk[min chunk.size i + 8..min chunk.size i + 16]
            throw "INVALID_DATA"

      chunk = chunk[..chunk.size / 2]

    if is-swapped-16-in:
      // The ESP32 swaps every 16-bits.
      for i := 0; i < chunk.size; i += 4:
        tmp := chunk[i]
        chunk[i] = chunk[i + 2]
        chunk[i + 2] = tmp
        tmp = chunk[i + 1]
        chunk[i + 1] = chunk[i + 3]
        chunk[i + 3] = tmp

    return chunk

  update-iterations:
    iterations++
    i := 0
    while true:
      pos := i

      if stereo-out == i2s.Bus.SLOTS-STEREO-LEFT or stereo-in == i2s.Bus.SLOTS-MONO-LEFT:
        pos *= 2
      else if stereo-out == i2s.Bus.SLOTS-STEREO-RIGHT or stereo-in == i2s.Bus.SLOTS-MONO-RIGHT:
        pos = pos * 2 + bytes-per-sample

      if is-8-bit-esp32:
        pos = pos * 2 + 1
      else if is-24-bit-esp32:
        pos = pos + pos / 3 + 1

      if is-swapped-16-out: pos += 2

      if pos >= raw.size: break
      raw[pos] = iterations
      i += 8

class VerifyingDataGenerator implements DataGenerator:
  data_/VerifiableData
  bits-per-sample/int
  stereo-in/int?
  stereo-out/int?
  offset_/int := 0
  written/int := 0
  /// The amount of bytes for both samples.
  full-size_/int
  bytes-per-sample/int

  is-synchronized_/bool := false

  verified-count_/int := 0
  verification-offset_/int := 0
  /// Allow as many leading 0s as necessary.
  needs-synchronization/bool
  /// Allow just full-size_ leading 0s.
  allow-leading-0-samples/bool
  /// Allow missing first samples.
  allow-missing-first-samples/bool

  allowed-errors/int
  encountered-errors/int := 0

  constructor
      .bits-per-sample
      --.stereo-in/int?=null
      --.stereo-out/int?=null
      --.needs-synchronization/bool=false
      --.allow-leading-0-samples/bool=false
      --.allow-missing-first-samples/bool=false
      --.allowed-errors/int=0:
    // 2 slots.
    full-size_ = bits-per-sample / 4
    bytes-per-sample = bits-per-sample / 8
    data_ = VerifiableData bits-per-sample
        --stereo-in=stereo-in
        --stereo-out=stereo-out

  do [block] -> int:
    raw := data_.raw
    consumed := block.call raw[offset_..]
    offset_ += consumed
    if offset_ == raw.size:
      offset_ = 0
      data_.update-iterations

    if bits-per-sample == 8 and system.architecture == system.ARCHITECTURE-ESP32:
      // The ESP32 only uses the MSB of 16-bit chunks.
      written += consumed / 2
    else if bits-per-sample == 24 and system.architecture == system.ARCHITECTURE-ESP32:
      // The ESP32 only uses the 24MSB of 32-bit chunks.
      written += (consumed * 3) >> 2
    else:
      written += consumed
    return consumed

  verify-byte_ data/int --at/int --iteration -> bool:
    if at & 0b111 == 0:
      // The iteration.
      return data == iteration & 0xff
    else if at & 0b111 == 1:
      // The repetition counter.
      return data == at >> 3
    else:
      return data == at & 0xff

  verify chunk/ByteArray:
    // List.chunk-up 0 chunk.size 16: | from to |
    //   print chunk[from..to]

    e := catch:
      chunk = data_.fix-chunk chunk
    if e:
      print "Error while fixing the chunk: $e"
      increment-error
      return
    verify-fixed chunk

  verify-fixed chunk/ByteArray:
    if needs-synchronization and not is-synchronized_:
      found-synchronization := false
      print "Trying to synchronize on $chunk[..min chunk.size 16]"
      for i := 0; i < chunk.size - 16; i += bytes-per-sample:
        // In the same iteration.
        if chunk[i] != chunk[i + 8]: continue
        // With a repetition counter that increments.
        if chunk[i + 1] + 1 != chunk[i + 9]: continue
        high := chunk[i + 2] & 0xF0
        matches := true
        for j := 2; j < 16; j++:
          if j == 8 or j == 9: continue
          byte := chunk[i + j]
          if byte & 0xF0 != high:
            matches = false
            break
          if byte & 0x0F != j:
            matches = false
            break
        if not matches: continue
        is-synchronized_ = true
        print "synchronized: $chunk[i..i + 16]"
        // Compute reasonable values for the offset.
        iteration := chunk[i]
        repetition-counter := chunk[i + 1]
        verification-offset_ = iteration * data_.size + repetition-counter * 8
        chunk = chunk[i..]
        break
      if not is-synchronized_: return

    if verification-offset_ == 0 and allow-leading-0-samples:
      // We assume that there are at least full-size_ bytes.
      all-zeroes := true
      for i := 0; i < full-size_; i++:
        if chunk[i] != 0:
          // We found a non-zero sample.
          all-zeroes = false
          break
      if all-zeroes:
        chunk = chunk[full-size_..]

    offset := verification-offset_
    data-offset := offset % data_.size
    iteration := offset / data_.size
    for i := 0; i < chunk.size; i++:
      data-index := data-offset + i
      if data-index == data_.size:
        data-offset = -i
        iteration++
        data-index = 0

      if not verify-byte_ chunk[i] --at=data-index --iteration=iteration:
        // We found a mismatch.
        // Could be because we missed the first samples.
        if verification-offset_ == 0 and allow-missing-first-samples:
          // We probably just missed the first samples.
          verification-offset_ += full-size_
          verify-fixed chunk
          return
        print "Mismatch at $i (data-index=$data-index) (offset: $verified-count_) $(%02x chunk[i])"
        print "Iteration: $(%x iteration)"
        print "Repetition: $(%x data-index / 8)"
        print chunk[max 0 i - 16..max 0 i - 8]
        print chunk[max 0 i - 8..i]
        print "$chunk[i..min chunk.size i + 8]  <- first byte here"
        print chunk[min chunk.size i + 8..min chunk.size i + 16]
        increment-error
        if i < 2:
          // Assume that we are not synchronized anymore.
          // This is just a heuristic.
          is-synchronized_ = false
        break
    verification-offset_ += chunk.size
    verified-count_ += chunk.size

  verified -> int:
    return verified-count_

  increment-error:
    encountered-errors++
    if encountered-errors > allowed-errors:
      expect false

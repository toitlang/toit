// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import .hw.shared.i2s-pattern

stream data/ByteArray start/int count/int -> ByteArray:
  return ByteArray count: data[(start + it) % data.size]

reject [block]:
  error := catch: block.call
  expect (error is string)

main:
  // Independent wire examples: little endian, distinct left/right values,
  // and significant high bits at every width.
  expect-equals #[0x67, 0x65, 0x66, 0x2a] (pattern 8)[..4]
  expect-equals #[0x67, 0x45, 0x65, 0x8b] (pattern 16)[..4]
  expect-equals #[0x67, 0x45, 0x23, 0x65, 0x8b, 0xa9] (pattern 24)[..6]
  expect-equals #[0x67, 0x45, 0x23, 0x81, 0x65, 0x8b, 0xa9, 0xf0] (pattern 32)[..8]
  reject: pattern 7
  reject: pattern 16 --slots=6
  // Golden physical samples cover muted slots and duplicated mono samples.
  golden := [#[0x67, 0x45, 0x65, 0x8b], #[0x67, 0x45, 0, 0],
    #[0, 0, 0x65, 0x8b], #[0x67, 0x45, 0x67, 0x45],
    #[0x67, 0x45, 0, 0], #[0, 0, 0x65, 0x8b]]
  6.repeat: |slots/int|
    expect-equals golden[slots] (wire-pattern 16 slots)[..4]
    [8, 16, 24, 32].do: |bits/int|
      wire := wire-pattern bits slots --inverted
      verifier := SequenceVerifier bits --wire-slots=slots --inverted --start-frame=0
      verifier.accept wire wire.size
      // Muted slots must remain zero; mono-both must duplicate left data.
      sample-bytes := bits / 8
      if slots != i2s.Bus.SLOTS-STEREO-BOTH:
        changed := wire.copy
        offset := [2, 5].contains slots ? 0 : sample-bytes
        changed[offset] ^= 1
        reject:
          strict := SequenceVerifier bits --wire-slots=slots --inverted --start-frame=0
          strict.accept changed changed.size
      reject:
        strict := SequenceVerifier bits --wire-slots=slots --inverted --start-frame=0
        dropped := wire[(sample-bytes * 2)..]
        strict.accept dropped dropped.size
  count := 0
  [8, 16, 24, 32].do: |bits/int|
    [i2s.Bus.SLOTS-STEREO-BOTH, i2s.Bus.SLOTS-MONO-LEFT, i2s.Bus.SLOTS-MONO-RIGHT].do: |slots/int|
      data := pattern bits --slots=slots
      // Opposite directions must not accept one another's stream, even if
      // the verifier can choose any starting phase in the 251-frame cycle.
      inverted := pattern bits --slots=slots --inverted
      data.size.repeat: expect-equals (data[it] ^ 0xff) inverted[it]
      reverse-verifier := SequenceVerifier bits --slots=slots --inverted
      reverse-verifier.accept inverted inverted.size
      reject:
        wrong := SequenceVerifier bits --slots=slots
        wrong.accept inverted inverted.size
      reject:
        wrong := SequenceVerifier bits --slots=slots --inverted
        wrong.accept data data.size
      frame := data.size / PERIOD
      [TRAINING-FRAMES - 1, TRAINING-FRAMES].do: |training/int|
        framed := TrainingSequenceVerifier bits --slots=slots
        zeros := ByteArray (training * frame)
        // Training may span several reads or end partway through a read.
        framed.accept zeros[..frame] frame
        joined := zeros[frame..] + data
        framed.accept joined joined.size
        framed.finish
        expect-equals training framed.training-frames
        expect-equals data.size framed.checked-bytes
      [0, TRAINING-FRAMES - 2, TRAINING-FRAMES + 1].do: |training/int|
        reject:
          framed := TrainingSequenceVerifier bits --slots=slots
          joined := (ByteArray (training * frame)) + data
          framed.accept joined joined.size
      reject:
        strict := TrainingSequenceVerifier bits --slots=slots --minimum-training=TRAINING-FRAMES
        joined := (ByteArray ((TRAINING-FRAMES - 1) * frame)) + data
        strict.accept joined joined.size
      reject:
        framed := TrainingSequenceVerifier bits --slots=slots
        joined := (ByteArray (TRAINING-FRAMES * frame)) + data[frame..]
        framed.accept joined joined.size
      reject:
        framed := TrainingSequenceVerifier bits --slots=slots
        zeros := ByteArray (TRAINING-FRAMES * frame)
        framed.accept zeros zeros.size
        framed.finish
      reject:
        framed := TrainingSequenceVerifier bits --slots=slots
        joined := (ByteArray (TRAINING-FRAMES * frame)) + data
        joined[frame] = 1
        framed.accept joined joined.size
      fixed := SequenceVerifier bits --slots=slots --start-frame=0
      fixed.accept data data.size
      reject:
        shifted := SequenceVerifier bits --slots=slots --start-frame=0
        wrong-start := stream data frame data.size
        shifted.accept wrong-start wrong-start.size
      reject: SequenceVerifier bits --slots=slots --start-frame=PERIOD
      reject: SequenceVerifier bits --slots=slots --start-frame=-1
      verifier := SequenceVerifier bits --slots=slots
      offset := 197 * frame
      total := 0
      [1, 63, 64, 65, 127, 251, 254].do: |frames/int|
        n := frames * frame
        // Bytes beyond the native read count may contain old buffer contents.
        buffer := stream data offset (n + 5)
        5.repeat: buffer[n + it] = 0xff
        verifier.accept buffer n
        offset += n
        total += n
      expect-equals total verifier.checked-bytes

      // A dropped or repeated whole DMA block passes a constant-frame test.
      // It must fail here without silently choosing a fresh starting phase.
      [0, 128].do: |next-frame/int|
        broken := SequenceVerifier bits --slots=slots
        prefix := stream data 0 (64 * frame)
        broken.accept prefix prefix.size
        following := stream data (next-frame * frame) (64 * frame)
        reject: broken.accept following following.size

      changed := SequenceVerifier bits --slots=slots
      first := stream data 0 frame
      changed.accept first frame
      corrupt := stream data frame frame
      corrupt[0] ^= 1
      reject: changed.accept corrupt frame
      reject: changed.accept first 0
      reject: changed.accept first (frame + 1)
      if frame > 1: reject: changed.accept first (frame - 1)

      if slots == i2s.Bus.SLOTS-STEREO-BOTH:
        swapped := SequenceVerifier bits --slots=slots
        swapped.accept first frame
        second := stream data frame frame
        half := frame / 2
        reversed := second[half..] + second[..half]
        reject: swapped.accept reversed frame
      count++
  expect-equals 12 count
  print "I2S sequence verifier: 12 width/slot cases, wrap, partial reads, corruption and DMA block loss/replay PASS"

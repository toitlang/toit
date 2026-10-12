// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .hw.shared.i2s-pattern

main:
  [8, 16, 24, 32].do: |bits/int|
    [false, true].do: |inverted/bool|
      frame := bits / 8 * 2
      data := pattern bits --inverted=inverted
      stream := ByteArray (TRAINING-FRAMES * frame)
      40.repeat: stream += data
      [1, 63, 64, 251, 512].do: |chunk-frames/int|
        verify stream bits inverted chunk-frames
        // Inject faults well after startup, across reused-buffer boundaries.
        offset := 4200 * frame
        corrupt := stream.copy
        corrupt[offset] ^= 1
        expect (catch: verify corrupt bits inverted chunk-frames) != null
        dropped := stream[..offset] + stream[offset + 64 * frame..]
        expect (catch: verify dropped bits inverted chunk-frames) != null
        replayed := stream[..offset] + stream[offset - 64 * frame..]
        expect (catch: verify replayed bits inverted chunk-frames) != null
    check-startup bits
  print "Streaming verifier: reused buffers, all widths/directions, late corruption/drop/replay PASS"

// The S3 startup allowance is explicit and bounded. It cannot hide a second
// arbitrary frame, extra training, or a missing first payload frame.
check-startup bits/int:
  frame := bits / 8 * 2
  data := pattern bits
  [0, 1].do: |extra/int|
    stream := (ByteArray ((1 + TRAINING-FRAMES + extra) * frame)) + data
    stream[0] = 0xab
    strict := TrainingSequenceVerifier bits
    expect (catch: strict.accept stream stream.size) != null
    allowed := TrainingSequenceVerifier bits --allow-partial-first --startup-extra=extra
    (stream.size / frame).repeat: |index/int|
      allowed.accept stream[index * frame..(index + 1) * frame] frame
    allowed.finish
    expect-equals (TRAINING-FRAMES + extra) allowed.training-frames
    expect-equals data.size allowed.checked-bytes
    expect-equals stream[..frame] allowed.initial-frame
    if extra == 1:
      bounded := TrainingSequenceVerifier bits --allow-partial-first
      expect (catch: bounded.accept stream stream.size) != null
    missing := stream[..(1 + TRAINING-FRAMES + extra) * frame] + data[frame..]
    first-payload := TrainingSequenceVerifier bits --allow-partial-first --startup-extra=extra
    expect (catch: first-payload.accept missing missing.size) != null
    stream[frame] = 0xab
    second := TrainingSequenceVerifier bits --allow-partial-first --startup-extra=extra
    expect (catch: second.accept stream stream.size) != null
  // A partial frame cannot make up for missing zero training, and skipping
  // it must happen only once even when it arrives in its own read.
  short := (ByteArray ((TRAINING-FRAMES - 1) * frame)) + data
  short[0] = 0xab
  insufficient := TrainingSequenceVerifier bits --allow-partial-first
  insufficient.accept short[..frame] frame
  expect (catch: insufficient.accept short[frame..] (short.size - frame)) != null
  [-1, 2].do: |extra/int|
    expect-throw "INVALID_ARGUMENT":
      TrainingSequenceVerifier bits --startup-extra=extra

verify stream/ByteArray bits/int inverted/bool chunk-frames/int:
  frame := bits / 8 * 2
  buffer := ByteArray (chunk-frames * frame)
  verifier := TrainingSequenceVerifier bits --inverted=inverted
      --allow-partial-first=inverted
  offset := 0
  while offset < stream.size:
    count := min buffer.size (stream.size - offset)
    buffer.replace 0 stream[offset..offset + count]
    verifier.accept buffer count
    offset += count
    buffer.fill 0xff
  verifier.finish
  expect-equals (stream.size - TRAINING-FRAMES * frame) verifier.checked-bytes

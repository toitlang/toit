// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests native audio DSP primitives on the ESP32.

The test skips the corresponding section when an envelope was built without
  its optional audio configuration flag.
*/

import audio
import expect show *
import io
import math

import .test

FFT-SIZE ::= 256
FFT-BIN ::= 13

main:
  run-test: test

test:
  if not is-common-audio-enabled:
    print "Common audio primitives are disabled in this envelope."
    return

  test-common

  if not is-extra-audio-enabled:
    print "Extra audio DSP primitives are disabled in this envelope."
    return

  test-fft
  test-gcc-phat
  test-fir
  test-biquad
  test-resampler

is-common-audio-enabled -> bool:
  exception := catch:
    audio.peak-absolute #[] --format=audio.PCM-S16-LE
  if not exception: return true
  if exception == "UNIMPLEMENTED": return false
  throw exception

is-extra-audio-enabled -> bool:
  plan := audio.RealFftQ15Plan 2
  exception := catch:
    plan.power-spectrum (pcm16 [0, 0])
        --destination=(ByteArray plan.output-byte-size)
        --format=audio.PCM-S16-LE
  if not exception: return true
  if exception == "UNIMPLEMENTED": return false
  throw exception

pcm16 values/List -> ByteArray:
  result := ByteArray (values.size * 2)
  values.size.repeat:
    io.LITTLE-ENDIAN.put-int16 result (it * 2) values[it]
  return result

expect-pcm16 expected/List actual/ByteArray:
  expect-equals (expected.size * 2) actual.size
  expected.size.repeat:
    expect-equals expected[it] (io.LITTLE-ENDIAN.int16 actual (it * 2))

test-common:
  source := pcm16 [-32_768, 0, 32_767, 0]
  expect-equals 1.0 (audio.peak-absolute source --format=audio.PCM-S16-LE)
  expect-equals 0.5 (audio.clipping-rate source --format=audio.PCM-S16-LE)

  ramp-source := pcm16 [10_000, 20_000, 10_000, 20_000]
  output := ByteArray ramp-source.size
  expect-equals 4 (audio.pcm-mix-ramp ramp-source
      --second=(pcm16 [0, 0, 0, 0])
      --destination=output
      --format=audio.PCM-S16-LE
      --first-start-q15=0
      --first-end-q15=audio.Q15-ONE
      --second-start-q15=0
      --second-end-q15=0
      --channels=2)
  expect-pcm16 [0, 0, 10_000, 20_000] output

test-fft:
  source := ByteArray (FFT-SIZE * 2)
  FFT-SIZE.repeat: | i |
    angle := 2.0 * math.PI * FFT-BIN * i / FFT-SIZE
    sample := (30_000.0 * (math.sin angle)).round
    io.LITTLE-ENDIAN.put-int16 source (i * 2) sample

  plan := audio.RealFftQ15Plan FFT-SIZE
  power := ByteArray plan.output-byte-size
  20.repeat:
    expect-equals plan.bin-count (plan.power-spectrum source
        --destination=power
        --format=audio.PCM-S16-LE)

  peak-index := 0
  peak-power := 0.0
  plan.bin-count.repeat: | i |
    value := io.LITTLE-ENDIAN.float32 power (i * 4)
    if value > peak-power:
      peak-index = i
      peak-power = value
  expect-equals FFT-BIN peak-index
  expect peak-power > 0.20
  expect peak-power < 0.22

test-gcc-phat:
  plan := audio.GccPhatQ15Plan 256 --max-delay=32
  first := ByteArray 512
  second := ByteArray 512
  io.LITTLE-ENDIAN.put-int16 first (37 * 2) 20_000
  io.LITTLE-ENDIAN.put-int16 second (54 * 2) 20_000
  10.repeat:
    expect-equals 17 (plan.estimate-delay first
        --second=second
        --format=audio.PCM-S16-LE)

test-fir:
  filter := audio.FirFilter [0, 1] --channels=2
  output := ByteArray 8
  expect-equals 4 (filter.process (pcm16 [100, 200, 300, 400])
      --destination=output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [0, 0, 100, 200] output

test-biquad:
  delay := audio.BiquadCascade [0, 1, 0, 0, 0] --channels=2
  output := ByteArray 8
  expect-equals 4 (delay.process (pcm16 [100, 200, 300, 400])
      --destination=output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [0, 0, 100, 200] output

  continuation := ByteArray 4
  expect-equals 2 (delay.process (pcm16 [500, 600])
      --destination=continuation
      --format=audio.PCM-S16-LE)
  expect-pcm16 [300, 400] continuation

test-resampler:
  resampler := audio.LinearResampler 2 4 --channels=2
  source := pcm16 [0, 100, 1_000, 1_100, 2_000, 2_100]

  first := ByteArray 4
  expect-equals 1 (resampler.process source
      --destination=first
      --format=audio.PCM-S16-LE)
  expect-equals 1 resampler.consumed
  expect-pcm16 [0, 100] first

  remainder := ByteArray 16
  expect-equals 4 (resampler.process
      (pcm16 [1_000, 1_100, 2_000, 2_100])
      --destination=remainder
      --format=audio.PCM-S16-LE
      --last)
  expect-equals 2 resampler.consumed
  expect-pcm16 [500, 600, 1_000, 1_100, 1_500, 1_600, 2_000, 2_100]
      remainder

// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import audio
import expect show *
import io

main:
  test-conversion
  test-extraction
  test-mixing
  test-reductions
  test-framed-energy
  test-correlation
  test-goertzel
  test-fft
  test-gcc-phat
  test-fir
  test-biquad
  test-resampling
  test-errors

pcm16 values/List -> ByteArray:
  result := ByteArray (values.size * 2)
  values.size.repeat:
    io.LITTLE-ENDIAN.put-int16 result (it * 2) values[it]
  return result

expect-pcm16 expected/List actual/ByteArray:
  expect-equals (expected.size * 2) actual.size
  expected.size.repeat:
    expect-equals expected[it] (io.LITTLE-ENDIAN.int16 actual (it * 2))

expect-near expected/num actual/num --epsilon/float=0.0001:
  difference := (expected - actual).abs
  expect difference <= epsilon --message="Expected $actual to be within $epsilon of $expected"

test-conversion:
  source := pcm16 [-32_768, -16_384, 0, 16_384]
  signed-8 := ByteArray 4
  expect-equals 4 (audio.pcm-convert source --destination=signed-8
      --from=audio.PCM-S16-LE
      --to=audio.PCM-S8)
  expect-bytes-equal #[0x80, 0xc0, 0x00, 0x40] signed-8

  unsigned-8 := ByteArray 4
  expect-equals 4 (audio.pcm-convert source --destination=unsigned-8
      --from=audio.PCM-S16-LE
      --to=audio.PCM-U8)
  expect-bytes-equal #[0x00, 0x40, 0x80, 0xc0] unsigned-8

  signed-24 := ByteArray 12
  expect-equals 4 (audio.pcm-convert source --destination=signed-24
      --from=audio.PCM-S16-LE
      --to=audio.PCM-S24-LE)
  round-trip := ByteArray source.size
  expect-equals 4 (audio.pcm-convert signed-24 --destination=round-trip
      --from=audio.PCM-S24-LE
      --to=audio.PCM-S16-LE)
  expect-bytes-equal source round-trip

  signed-32 := ByteArray 16
  expect-equals 4 (audio.pcm-convert source --destination=signed-32
      --from=audio.PCM-S16-LE
      --to=audio.PCM-S32-LE)
  expect-equals 4 (audio.pcm-convert signed-32 --destination=round-trip
      --from=audio.PCM-S32-LE
      --to=audio.PCM-S16-LE)
  expect-bytes-equal source round-trip

  // Expanding conversion is safe in place.
  in-place := #[0x80, 0xc0, 0x00, 0x40, 0, 0, 0, 0]
  expect-equals 4 (audio.pcm-convert in-place --destination=in-place
      --from=audio.PCM-S8
      --to=audio.PCM-S16-LE)
  expect-pcm16 [-32_768, -16_384, 0, 16_384] in-place

test-extraction:
  stereo := pcm16 [10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 60, 61]
  output := ByteArray 6
  expect-equals 3 (audio.pcm-extract stereo --destination=output
      --format=audio.PCM-S16-LE
      --channels=2
      --channel=1
      --decimation=2)
  expect-pcm16 [11, 31, 51] output

test-mixing:
  first := pcm16 [30_000, -30_000, 1_000]
  second := pcm16 [10_000, -10_000, -2_000]
  output := ByteArray first.size
  expect-equals 3 (audio.pcm-mix first --second=second --destination=output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [32_767, -32_768, -1_000] output

  expect-equals 3 (audio.pcm-mix first --second=second --destination=output
      --format=audio.PCM-S16-LE
      --first-gain-q15=(audio.Q15-ONE / 2)
      --second-gain-q15=(audio.Q15-ONE / 2))
  expect-pcm16 [20_000, -20_000, -500] output

  ramp-source := pcm16 [10_000, 10_000, 10_000, 10_000]
  silence := pcm16 [0, 0, 0, 0]
  ramp-output := ByteArray ramp-source.size
  expect-equals 4 (audio.pcm-mix-ramp ramp-source
      --second=silence
      --destination=ramp-output
      --format=audio.PCM-S16-LE
      --first-start-q15=0
      --first-end-q15=audio.Q15-ONE
      --second-start-q15=0
      --second-end-q15=0)
  expect-pcm16 [0, 3_333, 6_666, 10_000] ramp-output

  stereo-ramp := pcm16 [10_000, 20_000, 10_000, 20_000]
  stereo-output := ByteArray stereo-ramp.size
  expect-equals 4 (audio.pcm-mix-ramp stereo-ramp
      --second=(pcm16 [0, 0, 0, 0])
      --destination=stereo-output
      --format=audio.PCM-S16-LE
      --first-start-q15=0
      --first-end-q15=audio.Q15-ONE
      --second-start-q15=0
      --second-end-q15=0
      --channels=2)
  expect-pcm16 [0, 0, 10_000, 20_000] stereo-output

test-reductions:
  source := pcm16 [-32_768, -16_384, 0, 16_384]
  expect-equals 1.5 (audio.dot-product source
      --second=source
      --format=audio.PCM-S16-LE)
  expect-equals 1.5 (audio.sum-of-squares source --format=audio.PCM-S16-LE)
  expect-equals 0.5 (audio.mean-absolute-energy source --format=audio.PCM-S16-LE)
  expect-equals 0.75 (audio.difference-energy source --format=audio.PCM-S16-LE)
  expect-equals 0.0 (audio.mean-absolute-energy #[] --format=audio.PCM-S16-LE)
  expect-equals 1.0 (audio.peak-absolute source --format=audio.PCM-S16-LE)
  expect-equals 0.5 (audio.clipping-rate
      pcm16 [-32_768, 32_767, 0, 1]
      --format=audio.PCM-S16-LE)
  expect-near (2.0 / 3.0) (audio.zero-crossing-rate
      pcm16 [-1, 0, 1, -1]
      --format=audio.PCM-S16-LE)

test-framed-energy:
  source := pcm16 [-32_768, -16_384, 0, 16_384]
  output := ByteArray 8
  expect-equals 2 (audio.framed-sum-of-squares source --destination=output
      --format=audio.PCM-S16-LE
      --frame-size=2)
  expect-equals 1.25 (io.LITTLE-ENDIAN.float32 output 0)
  expect-equals 0.25 (io.LITTLE-ENDIAN.float32 output 4)

  expect-equals 2 (audio.framed-difference-energy source --destination=output
      --format=audio.PCM-S16-LE
      --frame-size=2)
  expect-equals 0.25 (io.LITTLE-ENDIAN.float32 output 0)
  expect-equals 0.25 (io.LITTLE-ENDIAN.float32 output 4)

test-correlation:
  signal := pcm16 [3_000, 2_000, 1_000, 2_000, 3_000]
  pattern := pcm16 [1_000, 2_000, 3_000]
  output := ByteArray 12
  expect-equals 3 (audio.normalized-correlation signal
      --pattern=pattern
      --destination=output
      --format=audio.PCM-S16-LE)
  expect-near -1.0 (io.LITTLE-ENDIAN.float32 output 0)
  expect-near 0.0 (io.LITTLE-ENDIAN.float32 output 4)
  expect-near 1.0 (io.LITTLE-ENDIAN.float32 output 8)

  constant := pcm16 [1_000, 1_000, 1_000]
  expect-equals 3 (audio.normalized-correlation signal
      --pattern=constant
      --destination=output
      --format=audio.PCM-S16-LE)
  3.repeat:
    expect-equals 0.0 (io.LITTLE-ENDIAN.float32 output (it * 4))

test-goertzel:
  source := pcm16 [0, 23_170, 32_767, 23_170, 0, -23_170, -32_768, -23_170]
  plan := audio.GoertzelPlan [1, 2] --sample-rate=8
  output := ByteArray (plan.output-size * 4)
  expect-equals 2 (plan.run source
      --destination=output
      --format=audio.PCM-S16-LE)
  at-one-hz := io.LITTLE-ENDIAN.float32 output 0
  at-two-hz := io.LITTLE-ENDIAN.float32 output 4
  expect at-one-hz > 15.0
  expect at-two-hz < 0.001

test-fft:
  source := pcm16 [0, 23_170, 32_767, 23_170, 0, -23_170, -32_768, -23_170]
  plan := audio.RealFftQ15Plan 8
  expect-equals 5 plan.bin-count
  power := ByteArray plan.output-byte-size
  expect-equals plan.bin-count (plan.power-spectrum source --destination=power
      --format=audio.PCM-S16-LE)
  bin-one := io.LITTLE-ENDIAN.float32 power 4
  expect-near 0.25 bin-one --epsilon=0.001
  expect (io.LITTLE-ENDIAN.float32 power 0) < 0.0001
  expect (io.LITTLE-ENDIAN.float32 power 8) < 0.0001

  spectrum := ByteArray plan.output-byte-size
  expect-equals plan.bin-count (plan.transform source --destination=spectrum
      --format=audio.PCM-S16-LE)
  expect (io.LITTLE-ENDIAN.int16 spectrum 6) < -16_000

  muted := audio.RealFftQ15Plan 8 --window=[0, 0, 0, 0, 0, 0, 0, 0]
  expect-equals muted.bin-count (muted.power-spectrum source --destination=power
      --format=audio.PCM-S16-LE)
  muted.bin-count.repeat:
    expect-equals 0.0 (io.LITTLE-ENDIAN.float32 power (it * 4))

test-gcc-phat:
  plan := audio.GccPhatQ15Plan 8 --max-delay=3
  first := pcm16 [0, 20_000, 0, 0, 0, 0, 0, 0]
  delayed := pcm16 [0, 0, 0, 20_000, 0, 0, 0, 0]
  expect-equals 2 (plan.estimate-delay first
      --second=delayed
      --format=audio.PCM-S16-LE)
  expect-equals -2 (plan.estimate-delay delayed
      --second=first
      --format=audio.PCM-S16-LE)

test-fir:
  filter := audio.FirFilter [0.5, 0.25]
  first := ByteArray 4
  expect-equals 2 (filter.process (pcm16 [10_000, 0])
      --destination=first
      --format=audio.PCM-S16-LE)
  expect-pcm16 [5_000, 2_500] first
  continuation := ByteArray 2
  expect-equals 1 (filter.process (pcm16 [4_000])
      --destination=continuation
      --format=audio.PCM-S16-LE)
  expect-pcm16 [2_000] continuation

  stereo := audio.FirFilter [0, 1] --channels=2
  stereo-output := ByteArray 8
  expect-equals 4 (stereo.process (pcm16 [100, 200, 300, 400])
      --destination=stereo-output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [0, 0, 100, 200] stereo-output

test-biquad:
  delay := audio.BiquadCascade [0, 1, 0, 0, 0]
  first-output := ByteArray 4
  expect-equals 2 (delay.process (pcm16 [1_000, 2_000])
      --destination=first-output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [0, 1_000] first-output
  second-output := ByteArray 2
  expect-equals 1 (delay.process (pcm16 [3_000]) --destination=second-output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [2_000] second-output
  delay.reset
  expect-equals 1 (delay.process (pcm16 [4_000]) --destination=second-output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [0] second-output

  stereo-delay := audio.BiquadCascade [0, 1, 0, 0, 0] --channels=2
  stereo-output := ByteArray 8
  expect-equals 4 (stereo-delay.process (pcm16 [100, 200, 300, 400])
      --destination=stereo-output
      --format=audio.PCM-S16-LE)
  expect-pcm16 [0, 0, 100, 200] stereo-output

test-resampling:
  resampler := audio.LinearResampler 2 4
  output := ByteArray 10
  expect-equals 5 (resampler.process (pcm16 [0, 1_000, 2_000])
      --destination=output
      --format=audio.PCM-S16-LE
      --last)
  expect-equals 3 resampler.consumed
  expect-pcm16 [0, 500, 1_000, 1_500, 2_000] output

  resampler = audio.LinearResampler 4 2
  downsampled := ByteArray 6
  expect-equals 3 (resampler.process (pcm16 [0, 1_000, 2_000, 3_000, 4_000])
      --destination=downsampled
      --format=audio.PCM-S16-LE
      --last)
  expect-equals 5 resampler.consumed
  expect-pcm16 [0, 2_000, 4_000] downsampled

  resampler = audio.LinearResampler 2 4 --channels=2
  stereo-output := ByteArray 20
  expect-equals 5 (resampler.process
      (pcm16 [0, 100, 1_000, 1_100, 2_000, 2_100])
      --destination=stereo-output
      --format=audio.PCM-S16-LE
      --last)
  expect-equals 3 resampler.consumed
  expect-pcm16 [0, 100, 500, 600, 1_000, 1_100, 1_500, 1_600, 2_000, 2_100]
      stereo-output

  resampler = audio.LinearResampler 2 4
  first-part := ByteArray 2
  expect-equals 1 (resampler.process (pcm16 [0, 1_000, 2_000])
      --destination=first-part
      --format=audio.PCM-S16-LE)
  expect-equals 1 resampler.consumed
  expect-pcm16 [0] first-part
  remainder := ByteArray 8
  expect-equals 4 (resampler.process (pcm16 [1_000, 2_000])
      --destination=remainder
      --format=audio.PCM-S16-LE
      --last)
  expect-equals 2 resampler.consumed
  expect-pcm16 [500, 1_000, 1_500, 2_000] remainder

test-errors:
  expect-throw "INVALID_ARGUMENT":
    audio.pcm-extract #[] --destination=#[]
        --format=audio.PCM-S16-LE
        --channels=0
        --channel=0
  expect-throw "INVALID_ARGUMENT":
    audio.GoertzelPlan [5] --sample-rate=8
  expect-throw "INVALID_ARGUMENT":
    audio.pcm-mix #[] --second=#[] --destination=#[]
        --format=audio.PCM-S16-LE
        --first-gain-q15=(audio.Q15-ONE * 3)
  plan := audio.GoertzelPlan [1] --sample-rate=8
  expect-throw "OUT_OF_RANGE":
    plan.run #[] --destination=#[] --format=audio.PCM-S16-LE
  expect-throw "INVALID_ARGUMENT":
    audio.RealFftQ15Plan 7
  expect-throw "INVALID_ARGUMENT":
    audio.RealFftQ15Plan 8 --window=[1]
  fft := audio.RealFftQ15Plan 8
  expect-throw "OUT_OF_RANGE":
    fft.transform (pcm16 [0, 0, 0, 0, 0, 0, 0, 0]) --destination=#[]
        --format=audio.PCM-S16-LE
  expect-throw "INVALID_ARGUMENT":
    audio.BiquadCascade [1, 0]
  expect-throw "INVALID_ARGUMENT":
    audio.GccPhatQ15Plan 8 --max-delay=5
  expect-throw "INVALID_ARGUMENT":
    audio.FirFilter []
  expect-throw "INVALID_ARGUMENT":
    audio.LinearResampler 0 8_000

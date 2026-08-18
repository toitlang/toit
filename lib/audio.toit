// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import math

/**
Bulk operations on packed PCM audio.

All operations use caller-owned byte arrays.  Samples are signed and
  little-endian, except for $PCM-U8.  Incomplete samples at the end of an input
  buffer are ignored.
*/

/** Unsigned 8-bit PCM, centered at 128. */
PCM-U8 ::= 0
/** Signed 8-bit PCM. */
PCM-S8 ::= 1
/** Signed little-endian 16-bit PCM. */
PCM-S16-LE ::= 2
/** Signed little-endian packed 24-bit PCM. */
PCM-S24-LE ::= 3
/** Signed little-endian 32-bit PCM. */
PCM-S32-LE ::= 4

/** A Q15 gain representing unity. */
Q15-ONE ::= 1 << 15

REDUCE-SUM-OF-SQUARES_ ::= 0
REDUCE-MEAN-ABSOLUTE_ ::= 1
REDUCE-DIFFERENCE-ENERGY_ ::= 2
REDUCE-PEAK-ABSOLUTE_ ::= 3
REDUCE-CLIPPING-RATE_ ::= 4
REDUCE-ZERO-CROSSING-RATE_ ::= 5

FRAME-SUM-OF-SQUARES_ ::= 0
FRAME-MEAN-ABSOLUTE_ ::= 1
FRAME-DIFFERENCE-ENERGY_ ::= 2

/**
Converts packed PCM samples from $from to $to.

Writes as many complete samples as fit in $destination and returns the number
  of samples written.  Source and destination may be the same byte array.
*/
pcm-convert source/ByteArray --destination/ByteArray --from/int --to/int -> int:
  return pcm-convert_ source destination from to

pcm-convert_ source/ByteArray destination/ByteArray from/int to/int -> int:
  #primitive.audio.pcm-convert

/**
Extracts one channel and optionally decimates the result.

The packed $source contains interleaved frames with $channels channels.  The
  selected $channel is zero based.  One selected sample is written for every
  $decimation input frames.  Returns the number of samples written.
*/
pcm-extract source/ByteArray --destination/ByteArray -> int
    --format/int
    --channels/int
    --channel/int
    --decimation/int=1:
  return pcm-extract_ source destination format channels channel decimation

pcm-extract_ source/ByteArray destination/ByteArray format/int channels/int channel/int decimation/int -> int:
  #primitive.audio.pcm-extract

/**
Mixes two packed PCM buffers with saturating arithmetic.

The gains are Q15 integers, where $Q15-ONE is unity, and must be between -2.0
  and 2.0 inclusive.  The shortest buffer or the destination capacity
  determines the number of samples written.  Either input may also be the
  destination.  Returns the number of samples written.
*/
pcm-mix first/ByteArray --second/ByteArray --destination/ByteArray -> int
    --format/int
    --first-gain-q15/int=Q15-ONE
    --second-gain-q15/int=Q15-ONE:
  return pcm-mix_ first second destination format
      first-gain-q15
      first-gain-q15
      second-gain-q15
      second-gain-q15
      1

/**
Mixes two packed PCM buffers while linearly changing their gains.

The start gains apply to the first frame and the end gains to the last.  A
  one-frame result uses the start gains.  All channels in a frame use the same
  gain.  This operation is useful for fades and crossfades without
  discontinuities between samples.
*/
pcm-mix-ramp first/ByteArray --second/ByteArray --destination/ByteArray -> int
    --format/int
    --first-start-q15/int=Q15-ONE
    --first-end-q15/int=Q15-ONE
    --second-start-q15/int=Q15-ONE
    --second-end-q15/int=Q15-ONE
    --channels/int=1:
  return pcm-mix_ first second destination format
      first-start-q15
      first-end-q15
      second-start-q15
      second-end-q15
      channels

pcm-mix_ first/ByteArray second/ByteArray destination/ByteArray format/int
    first-start-q15/int first-end-q15/int
    second-start-q15/int second-end-q15/int channels/int -> int:
  #primitive.audio.pcm-mix

/**
Returns the dot product of two PCM buffers.

Samples are normalized to the interval `[-1.0, 1.0)`.  The shortest buffer
  determines the number of samples used.
*/
dot-product first/ByteArray --second/ByteArray --format/int -> float:
  return dot-product_ first second format

dot-product_ first/ByteArray second/ByteArray format/int -> float:
  #primitive.audio.dot-product

/**
Returns the sum of the squared normalized samples in $source.
*/
sum-of-squares source/ByteArray --format/int -> float:
  return reduce_ source format REDUCE-SUM-OF-SQUARES_

/**
Returns the mean absolute value of the normalized samples in $source.

Returns `0.0` for an empty buffer.
*/
mean-absolute-energy source/ByteArray --format/int -> float:
  return reduce_ source format REDUCE-MEAN-ABSOLUTE_

/**
Returns the sum of the squared differences between adjacent normalized
  samples in $source.
*/
difference-energy source/ByteArray --format/int -> float:
  return reduce_ source format REDUCE-DIFFERENCE-ENERGY_

/** Returns the largest absolute normalized sample in $source. */
peak-absolute source/ByteArray --format/int -> float:
  return reduce_ source format REDUCE-PEAK-ABSOLUTE_

/**
Returns the fraction of samples at the positive or negative PCM limit.

Returns `0.0` for an empty buffer.
*/
clipping-rate source/ByteArray --format/int -> float:
  return reduce_ source format REDUCE-CLIPPING-RATE_

/**
Returns the fraction of adjacent sample pairs that cross zero.

Zero belongs to the non-negative side.  Returns `0.0` for fewer than two
  samples.
*/
zero-crossing-rate source/ByteArray --format/int -> float:
  return reduce_ source format REDUCE-ZERO-CROSSING-RATE_

reduce_ source/ByteArray format/int operation/int -> float:
  #primitive.audio.reduce

/**
Writes framed energy values to $destination without allocating.

Each result is a little-endian float32.  Frames contain $frame-size samples and
  start $hop-size samples apart.  Returns the number of results written.
*/
framed-sum-of-squares source/ByteArray --destination/ByteArray -> int
    --format/int
    --frame-size/int
    --hop-size/int=frame-size:
  return framed-energy_ source destination format frame-size hop-size FRAME-SUM-OF-SQUARES_

/**
Writes the mean absolute energy of successive frames to $destination.

See $framed-sum-of-squares for the buffer layout and framing rules.
*/
framed-mean-absolute-energy source/ByteArray --destination/ByteArray -> int
    --format/int
    --frame-size/int
    --hop-size/int=frame-size:
  return framed-energy_ source destination format frame-size hop-size FRAME-MEAN-ABSOLUTE_

/**
Writes the difference energy of successive frames to $destination.

See $framed-sum-of-squares for the buffer layout and framing rules.
*/
framed-difference-energy source/ByteArray --destination/ByteArray -> int
    --format/int
    --frame-size/int
    --hop-size/int=frame-size:
  return framed-energy_ source destination format frame-size hop-size FRAME-DIFFERENCE-ENERGY_

framed-energy_ source/ByteArray destination/ByteArray format/int frame-size/int hop-size/int operation/int -> int:
  #primitive.audio.framed-energy

/**
Writes normalized sliding correlation values to $destination.

Each result is a little-endian float32 Pearson correlation coefficient.  The
  first result compares $pattern with the start of $signal, and subsequent
  results advance by one sample.  Returns the number of results written.

This operation requires the `TOIT_AUDIO_EXTRA` firmware option.
*/
normalized-correlation signal/ByteArray --pattern/ByteArray
    --destination/ByteArray --format/int -> int:
  return normalized-correlation_ signal pattern destination format

normalized-correlation_ signal/ByteArray pattern/ByteArray destination/ByteArray format/int -> int:
  #primitive.audio.normalized-correlation

/**
A reusable bank of Goertzel frequency detectors.

Coefficient setup happens once in Toit.  Calls to $run use native code and do
  not allocate.  Native Goertzel support requires the `TOIT_AUDIO_EXTRA`
  firmware option.
*/
class GoertzelPlan:
  coefficients_/ByteArray

  /** Number of float32 values required in the output of $run. */
  output-size/int

  /**
  Constructs a detector for $frequencies measured at $sample-rate.

  Frequencies must be between zero and the Nyquist frequency, inclusive.
  */
  constructor frequencies/List --sample-rate/int:
    if sample-rate <= 0: throw "INVALID_ARGUMENT"
    output-size = frequencies.size
    coefficients_ = ByteArray (frequencies.size * 4)
    frequencies.size.repeat: | i |
      frequency/num := frequencies[i]
      if frequency < 0 or frequency * 2 > sample-rate:
        throw "INVALID_ARGUMENT"
      coefficient := 2.0 * (math.cos (2.0 * math.PI * frequency / sample-rate))
      io.LITTLE-ENDIAN.put-float32 coefficients_ (i * 4) coefficient

  /**
  Writes one power value per configured frequency to $destination.

  The results are little-endian float32 values.  The destination must have at
  least `output-size * 4` bytes.  Returns $output-size.
  */
  run source/ByteArray --destination/ByteArray --format/int -> int:
    if destination.size < output-size * 4: throw "OUT_OF_RANGE"
    return goertzel_ source coefficients_ destination format

goertzel_ source/ByteArray coefficients/ByteArray destination/ByteArray format/int -> int:
  #primitive.audio.goertzel

/**
A reusable, scaled real FFT using Q15 arithmetic.

The transform is divided by two at every stage, so its complex result is
  scaled by `1 / size`.  Twiddles and scratch storage are allocated only when
  the plan is constructed.  Native FFT support requires the
  `TOIT_AUDIO_EXTRA` firmware option.
*/
class RealFftQ15Plan:
  /** Number of real input samples. */
  size/int

  /** Number of non-redundant complex output bins. */
  bin-count/int

  twiddles_/ByteArray
  window_/ByteArray
  scratch_/ByteArray

  /**
  Constructs a power-of-two real FFT plan.

  The optional $window contains $size coefficients in the interval `[-1, 1]`.
    Coefficients are converted to Q15 once during construction.
  */
  constructor .size --window/List?=null:
    if size < 2 or size > 4_096 or not size.is-power-of-two:
      throw "INVALID_ARGUMENT"
    if window and window.size != size: throw "INVALID_ARGUMENT"
    bin-count = size / 2 + 1
    twiddles_ = q15-twiddles_ size
    scratch_ = ByteArray (size * 4)
    window_ = window ? ByteArray (size * 2) : #[]
    if window:
      size.repeat: | i |
        coefficient/num := window[i]
        if not coefficient.to-float.is-finite or
            coefficient < -1 or coefficient > 1:
          throw "INVALID_ARGUMENT"
        io.LITTLE-ENDIAN.put-int16 window_ (i * 2)
            q15-coefficient_ coefficient

  /** Number of bytes required for either transform output representation. */
  output-byte-size -> int:
    return bin-count * 4

  /**
  Writes the non-redundant Q15 complex bins to $destination.

  Each bin is a little-endian signed 16-bit real value followed by a signed
    16-bit imaginary value.  Returns $bin-count.
  */
  transform source/ByteArray --destination/ByteArray --format/int -> int:
    if destination.size < output-byte-size: throw "OUT_OF_RANGE"
    return real-fft-q15_ source twiddles_ window_ scratch_ destination
        format
        size
        false

  /**
  Writes one little-endian float32 magnitude-squared value per FFT bin.

  Results include the transform's `1 / size` scaling.  Returns $bin-count.
  */
  power-spectrum source/ByteArray --destination/ByteArray --format/int -> int:
    if destination.size < output-byte-size: throw "OUT_OF_RANGE"
    return real-fft-q15_ source twiddles_ window_ scratch_ destination
        format
        size
        true

q15-coefficient_ value/num -> int:
  scaled := (value.to-float * 32_768).round
  return max -32_768 (min 32_767 scaled)

q15-twiddles_ size/int -> ByteArray:
  result := ByteArray (size * 2)
  (size / 2).repeat: | i |
    angle := -2.0 * math.PI * i / size
    io.LITTLE-ENDIAN.put-int16 result (i * 4)
        q15-coefficient_ (math.cos angle)
    io.LITTLE-ENDIAN.put-int16 result (i * 4 + 2)
        q15-coefficient_ (math.sin angle)
  return result

real-fft-q15_ source/ByteArray twiddles/ByteArray window/ByteArray
    scratch/ByteArray destination/ByteArray format/int size/int power/bool -> int:
  #primitive.audio.real-fft-q15

/**
A reusable GCC-PHAT delay estimator using Q15 FFTs.

The estimator compares blocks of up to $size samples and zero-pads shorter
  blocks.  A positive result means that `second` is delayed relative to
  `first`.
  Native GCC-PHAT support requires the `TOIT_AUDIO_EXTRA` firmware option.
*/
class GccPhatQ15Plan:
  /** FFT size and maximum number of input samples per block. */
  size/int
  /** Largest positive or negative delay considered by $estimate-delay. */
  max-delay/int

  twiddles_/ByteArray
  scratch_/ByteArray

  /** Constructs a power-of-two estimator with reusable scratch storage. */
  constructor .size --.max-delay=(size / 2):
    if size < 2 or size > 4_096 or not size.is-power-of-two or
        max-delay < 0 or max-delay > size / 2:
      throw "INVALID_ARGUMENT"
    twiddles_ = q15-twiddles_ size
    scratch_ = ByteArray (size * 8)

  /**
  Returns the estimated whole-sample delay in `[-max-delay, max-delay]`.

  Each input must contain at least one complete sample.  Samples beyond $size
    are ignored.  The operation does not allocate after plan construction.
  */
  estimate-delay first/ByteArray --second/ByteArray --format/int -> int:
    return gcc-phat-delay_ first second twiddles_ scratch_ format size max-delay

gcc-phat-delay_ first/ByteArray second/ByteArray twiddles/ByteArray
    scratch/ByteArray format/int size/int max-delay/int -> int:
  #primitive.audio.gcc-phat-delay

/**
A reusable streaming FIR filter with float32 coefficients and state.

Coefficient zero multiplies the current sample; subsequent coefficients
  multiply successively older samples.  Channels retain independent histories.
  Native FIR support requires the `TOIT_AUDIO_EXTRA` firmware option.
*/
class FirFilter:
  /** Number of interleaved channels processed independently. */
  channels/int

  coefficients_/ByteArray
  state_/ByteArray

  /** Constructs an FIR filter from one or more finite coefficients. */
  constructor coefficients/List --.channels=1:
    if channels <= 0 or channels > 32 or coefficients.is-empty:
      throw "INVALID_ARGUMENT"
    coefficients_ = ByteArray (coefficients.size * 4)
    coefficients.size.repeat: | i |
      coefficient/num := coefficients[i]
      if not coefficient.to-float.is-finite: throw "INVALID_ARGUMENT"
      io.LITTLE-ENDIAN.put-float32 coefficients_ (i * 4) coefficient.to-float
    state_ = ByteArray (4 + coefficients.size * channels * 4)

  /** Clears the retained sample history. */
  reset -> none:
    state_.fill 0

  /** Filters packed PCM from $source into $destination and returns its sample count. */
  process source/ByteArray --destination/ByteArray --format/int -> int:
    return fir_ source destination coefficients_ state_ format channels

fir_ source/ByteArray destination/ByteArray coefficients/ByteArray
    state/ByteArray format/int channels/int -> int:
  #primitive.audio.fir

/**
A reusable cascade of transposed-direct-form-II biquad sections.

Each section is specified as five coefficients `[b0, b1, b2, a1, a2]`, with
  the denominator convention `1 + a1*z^-1 + a2*z^-2`.  State is retained
  between calls and no processing-time allocation occurs.  Native biquad
  support requires the `TOIT_AUDIO_EXTRA` firmware option.  The caller is
  responsible for supplying stable coefficients.
*/
class BiquadCascade:
  /** Number of interleaved channels processed independently. */
  channels/int

  coefficients_/ByteArray
  state_/ByteArray

  /** Constructs a cascade from one or more groups of five coefficients. */
  constructor coefficients/List --.channels=1:
    if channels <= 0 or channels > 32 or coefficients.size == 0 or
        coefficients.size % 5 != 0:
      throw "INVALID_ARGUMENT"
    coefficients_ = ByteArray (coefficients.size * 4)
    coefficients.size.repeat: | i |
      coefficient/num := coefficients[i]
      if not coefficient.to-float.is-finite: throw "INVALID_ARGUMENT"
      io.LITTLE-ENDIAN.put-float32 coefficients_ (i * 4) coefficient.to-float
    state_ = ByteArray ((coefficients.size / 5) * channels * 8)

  /** Clears the retained delay state. */
  reset -> none:
    state_.fill 0

  /** Filters packed PCM from $source into $destination and returns its sample count. */
  process source/ByteArray --destination/ByteArray --format/int -> int:
    return biquad_ source destination coefficients_ state_ format channels

biquad_ source/ByteArray destination/ByteArray coefficients/ByteArray
    state/ByteArray format/int channels/int -> int:
  #primitive.audio.biquad

/**
A streaming linear PCM resampler with reusable state.

The caller advances its input by $consumed frames after each $process call.
  This permits bounded output buffers without dropping input.  Native
  resampling support requires the `TOIT_AUDIO_EXTRA` firmware option.
  Downsampling does not include an anti-aliasing low-pass filter; filter input
  first when it is not already band limited.
*/
class LinearResampler:
  source-rate/int
  destination-rate/int
  /** Number of interleaved channels processed independently. */
  channels/int

  state_/ByteArray

  constructor .source-rate .destination-rate --.channels=1:
    if source-rate <= 0 or source-rate > 1_000_000 or
        destination-rate <= 0 or destination-rate > 1_000_000 or
        channels <= 0 or channels > 32:
      throw "INVALID_ARGUMENT"
    state_ = ByteArray (16 + channels * 4)

  /** Number of input frames consumed by the most recent $process call. */
  consumed -> int:
    return io.LITTLE-ENDIAN.uint32 state_ 12

  /** Clears interpolation and stream-position state. */
  reset -> none:
    state_.fill 0

  /**
  Resamples as much of $source as fits in $destination.

  Returns the number of output frames written.  When $last is true, the final
    retained frame is emitted and the resampler resets after all final output
    fits.  If it does not fit, call again with an empty source and $last.
  */
  process source/ByteArray --destination/ByteArray
      --format/int --last/bool=false -> int:
    return resample-linear_ source destination state_ format
        source-rate
        destination-rate
        channels
        last

resample-linear_ source/ByteArray destination/ByteArray state/ByteArray
    format/int source-rate/int destination-rate/int channels/int last/bool -> int:
  #primitive.audio.resample-linear

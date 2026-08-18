// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "top.h"

#include "objects.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

#include <cmath>
#include <cstring>

namespace toit {

MODULE_IMPLEMENTATION(audio, MODULE_AUDIO)

#if defined(CONFIG_TOIT_AUDIO) && CONFIG_TOIT_AUDIO

enum PcmFormat {
  PCM_U8 = 0,
  PCM_S8 = 1,
  PCM_S16_LE = 2,
  PCM_S24_LE = 3,
  PCM_S32_LE = 4,
};

static int bytes_per_sample(int format) {
  switch (format) {
    case PCM_U8:
    case PCM_S8:
      return 1;
    case PCM_S16_LE:
      return 2;
    case PCM_S24_LE:
      return 3;
    case PCM_S32_LE:
      return 4;
    default:
      return 0;
  }
}

static int32 maximum_q31(int format) {
  switch (format) {
    case PCM_U8:
    case PCM_S8:
      return 0x7f000000;
    case PCM_S16_LE:
      return 0x7fff0000;
    case PCM_S24_LE:
      return 0x7fffff00;
    case PCM_S32_LE:
      return INT32_MAX;
    default:
      UNREACHABLE();
  }
}

// Reads a sample scaled to signed Q31.
static int32 read_q31(const uint8* source, int format) {
  switch (format) {
    case PCM_U8:
      return (static_cast<int32>(source[0]) - 128) * 0x01000000;
    case PCM_S8:
      return static_cast<int8>(source[0]) * 0x01000000;
    case PCM_S16_LE: {
      uint16 bits = static_cast<uint16>(source[0]) |
                    (static_cast<uint16>(source[1]) << 8);
      return static_cast<int16>(bits) * 0x00010000;
    }
    case PCM_S24_LE: {
      uint32 bits = static_cast<uint32>(source[0]) |
                    (static_cast<uint32>(source[1]) << 8) |
                    (static_cast<uint32>(source[2]) << 16);
      if ((bits & 0x00800000) != 0) bits |= 0xff000000;
      return static_cast<int32>(bits) * 0x00000100;
    }
    case PCM_S32_LE: {
      uint32 bits = static_cast<uint32>(source[0]) |
                    (static_cast<uint32>(source[1]) << 8) |
                    (static_cast<uint32>(source[2]) << 16) |
                    (static_cast<uint32>(source[3]) << 24);
      return static_cast<int32>(bits);
    }
    default:
      UNREACHABLE();
  }
}

static void write_q31(uint8* destination, int format, int32 sample) {
  uint32 bits = static_cast<uint32>(sample);
  switch (format) {
    case PCM_U8:
      destination[0] = static_cast<uint8>((sample >> 24) + 128);
      break;
    case PCM_S8:
      destination[0] = static_cast<uint8>(sample >> 24);
      break;
    case PCM_S16_LE:
      destination[0] = static_cast<uint8>(bits >> 16);
      destination[1] = static_cast<uint8>(bits >> 24);
      break;
    case PCM_S24_LE:
      destination[0] = static_cast<uint8>(bits >> 8);
      destination[1] = static_cast<uint8>(bits >> 16);
      destination[2] = static_cast<uint8>(bits >> 24);
      break;
    case PCM_S32_LE:
      destination[0] = static_cast<uint8>(bits);
      destination[1] = static_cast<uint8>(bits >> 8);
      destination[2] = static_cast<uint8>(bits >> 16);
      destination[3] = static_cast<uint8>(bits >> 24);
      break;
    default:
      UNREACHABLE();
  }
}

static float normalized(int32 sample) {
  return static_cast<float>(sample) / 2147483648.0f;
}

static int32 saturate_q31(int64 sample) {
  if (sample > INT32_MAX) return INT32_MAX;
  if (sample < INT32_MIN) return INT32_MIN;
  return static_cast<int32>(sample);
}

static void put_float32_le(uint8* destination, float value) {
  uint32 bits;
  static_assert(sizeof(bits) == sizeof(value), "Unexpected float size");
  memcpy(&bits, &value, sizeof(bits));
  destination[0] = static_cast<uint8>(bits);
  destination[1] = static_cast<uint8>(bits >> 8);
  destination[2] = static_cast<uint8>(bits >> 16);
  destination[3] = static_cast<uint8>(bits >> 24);
}

#if defined(CONFIG_TOIT_AUDIO_EXTRA) && CONFIG_TOIT_AUDIO_EXTRA

static float read_float32_le(const uint8* source) {
  uint32 bits = static_cast<uint32>(source[0]) |
                (static_cast<uint32>(source[1]) << 8) |
                (static_cast<uint32>(source[2]) << 16) |
                (static_cast<uint32>(source[3]) << 24);
  float value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

static uint32 read_uint32_le(const uint8* source) {
  return static_cast<uint32>(source[0]) |
         (static_cast<uint32>(source[1]) << 8) |
         (static_cast<uint32>(source[2]) << 16) |
         (static_cast<uint32>(source[3]) << 24);
}

static void put_uint32_le(uint8* destination, uint32 value) {
  destination[0] = static_cast<uint8>(value);
  destination[1] = static_cast<uint8>(value >> 8);
  destination[2] = static_cast<uint8>(value >> 16);
  destination[3] = static_cast<uint8>(value >> 24);
}

static int16 read_int16_le(const uint8* source) {
  uint16 bits = static_cast<uint16>(source[0]) |
                (static_cast<uint16>(source[1]) << 8);
  return static_cast<int16>(bits);
}

static void put_int16_le(uint8* destination, int16 value) {
  uint16 bits = static_cast<uint16>(value);
  destination[0] = static_cast<uint8>(bits);
  destination[1] = static_cast<uint8>(bits >> 8);
}

static int16 saturate_q15(int32 sample) {
  if (sample > INT16_MAX) return INT16_MAX;
  if (sample < INT16_MIN) return INT16_MIN;
  return static_cast<int16>(sample);
}

static int32 normalized_to_q31(float sample) {
  if (std::isnan(sample)) return 0;
  if (sample >= 1.0f) return INT32_MAX;
  if (sample <= -1.0f) return INT32_MIN;
  return static_cast<int32>(sample * 2147483648.0f);
}

#endif  // CONFIG_TOIT_AUDIO_EXTRA.

enum Reduction {
  REDUCE_SUM_OF_SQUARES = 0,
  REDUCE_MEAN_ABSOLUTE = 1,
  REDUCE_DIFFERENCE_ENERGY = 2,
  REDUCE_PEAK_ABSOLUTE = 3,
  REDUCE_CLIPPING_RATE = 4,
  REDUCE_ZERO_CROSSING_RATE = 5,
};

static bool valid_reduction(int operation) {
  return operation >= REDUCE_SUM_OF_SQUARES &&
         operation <= REDUCE_ZERO_CROSSING_RATE;
}

static float reduce_samples(const uint8* source,
                            word sample_count,
                            int sample_bytes,
                            int format,
                            int operation) {
  if (sample_count == 0) return 0.0f;
  float result = 0.0f;
  if (operation == REDUCE_DIFFERENCE_ENERGY) {
    float previous = normalized(read_q31(source, format));
    for (word i = 1; i < sample_count; i++) {
      float current = normalized(read_q31(source + i * sample_bytes, format));
      float difference = current - previous;
      result += difference * difference;
      previous = current;
    }
    return result;
  }
  if (operation == REDUCE_ZERO_CROSSING_RATE) {
    if (sample_count < 2) return 0.0f;
    int32 previous = read_q31(source, format);
    word crossings = 0;
    for (word i = 1; i < sample_count; i++) {
      int32 current = read_q31(source + i * sample_bytes, format);
      if ((previous < 0 && current >= 0) ||
          (previous >= 0 && current < 0)) {
        crossings++;
      }
      previous = current;
    }
    return static_cast<float>(crossings) / (sample_count - 1);
  }
  word clipped = 0;
  for (word i = 0; i < sample_count; i++) {
    int32 raw = read_q31(source + i * sample_bytes, format);
    float sample = normalized(raw);
    if (operation == REDUCE_SUM_OF_SQUARES) {
      result += sample * sample;
    } else if (operation == REDUCE_MEAN_ABSOLUTE) {
      result += std::abs(sample);
    } else if (operation == REDUCE_PEAK_ABSOLUTE) {
      result = Utils::max(result, std::abs(sample));
    } else if (raw == INT32_MIN || raw == maximum_q31(format)) {
      clipped++;
    }
  }
  if (operation == REDUCE_MEAN_ABSOLUTE) result /= sample_count;
  if (operation == REDUCE_CLIPPING_RATE) {
    result = static_cast<float>(clipped) / sample_count;
  }
  return result;
}

#endif  // CONFIG_TOIT_AUDIO.

PRIMITIVE(pcm_convert) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, MutableBlob, destination, int, from, int, to);
  int source_bytes = bytes_per_sample(from);
  int destination_bytes = bytes_per_sample(to);
  if (source_bytes == 0 || destination_bytes == 0) FAIL(INVALID_ARGUMENT);
  word count = Utils::min(source.length() / source_bytes,
                          destination.length() / destination_bytes);

  const uint8* source_start = source.address();
  uint8* destination_start = destination.address();
  bool backwards = destination_start == source_start &&
                   destination_bytes > source_bytes;
  if (backwards) {
    for (word i = count; i > 0; i--) {
      int32 sample = read_q31(source_start + (i - 1) * source_bytes, from);
      write_q31(destination_start + (i - 1) * destination_bytes, to, sample);
    }
  } else {
    for (word i = 0; i < count; i++) {
      int32 sample = read_q31(source_start + i * source_bytes, from);
      write_q31(destination_start + i * destination_bytes, to, sample);
    }
  }
  return Smi::from(count);
#endif
}

PRIMITIVE(pcm_extract) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, MutableBlob, destination, int, format,
       int, channels, int, channel, int, decimation);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || channels <= 0 || channel < 0 || channel >= channels ||
      decimation <= 0) {
    FAIL(INVALID_ARGUMENT);
  }
  int64 frame_bytes = static_cast<int64>(sample_bytes) * channels;
  word input_frames = source.length() / frame_bytes;
  word available = input_frames == 0 ? 0 : (input_frames - 1) / decimation + 1;
  word count = Utils::min(available, destination.length() / sample_bytes);
  for (word i = 0; i < count; i++) {
    word source_sample = (i * decimation * channels) + channel;
    int32 sample = read_q31(source.address() + source_sample * sample_bytes, format);
    write_q31(destination.address() + i * sample_bytes, format, sample);
  }
  return Smi::from(count);
#endif
}

PRIMITIVE(pcm_mix) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, first, Blob, second, MutableBlob, destination, int, format,
       int, first_gain_start_q15, int, first_gain_end_q15,
       int, second_gain_start_q15, int, second_gain_end_q15, int, channels);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || channels <= 0 || channels > 32 ||
      first_gain_start_q15 < -0x10000 ||
      first_gain_start_q15 > 0x10000 || first_gain_end_q15 < -0x10000 ||
      first_gain_end_q15 > 0x10000 || second_gain_start_q15 < -0x10000 ||
      second_gain_start_q15 > 0x10000 || second_gain_end_q15 < -0x10000 ||
      second_gain_end_q15 > 0x10000) {
    FAIL(INVALID_ARGUMENT);
  }
  word count = Utils::min(first.length(), second.length()) / sample_bytes;
  count = Utils::min(count, destination.length() / sample_bytes);
  count -= count % channels;
  word frame_count = count / channels;
  for (word i = 0; i < count; i++) {
    word offset = i * sample_bytes;
    word frame = i / channels;
    int first_gain = first_gain_start_q15;
    int second_gain = second_gain_start_q15;
    if (frame_count > 1) {
      first_gain += static_cast<int>((static_cast<int64>(first_gain_end_q15 -
          first_gain_start_q15) * frame) / (frame_count - 1));
      second_gain += static_cast<int>((static_cast<int64>(second_gain_end_q15 -
          second_gain_start_q15) * frame) / (frame_count - 1));
    }
    int64 mixed = static_cast<int64>(read_q31(first.address() + offset, format)) *
                    first_gain;
    mixed += static_cast<int64>(read_q31(second.address() + offset, format)) *
             second_gain;
    write_q31(destination.address() + offset, format,
              saturate_q31(mixed >> 15));
  }
  return Smi::from(count);
#endif
}

PRIMITIVE(dot_product) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, first, Blob, second, int, format);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0) FAIL(INVALID_ARGUMENT);
  word count = Utils::min(first.length(), second.length()) / sample_bytes;
  float result = 0.0f;
  for (word i = 0; i < count; i++) {
    word offset = i * sample_bytes;
    result += normalized(read_q31(first.address() + offset, format)) *
              normalized(read_q31(second.address() + offset, format));
  }
  return Primitive::allocate_double(result, process);
#endif
}

PRIMITIVE(reduce) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, int, format, int, operation);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || !valid_reduction(operation)) FAIL(INVALID_ARGUMENT);
  word count = source.length() / sample_bytes;
  float result = reduce_samples(source.address(), count, sample_bytes, format,
                                operation);
  return Primitive::allocate_double(result, process);
#endif
}

PRIMITIVE(framed_energy) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, MutableBlob, destination, int, format,
       int, frame_size, int, hop_size, int, operation);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || frame_size <= 0 || hop_size <= 0 ||
      !valid_reduction(operation)) {
    FAIL(INVALID_ARGUMENT);
  }
  word sample_count = source.length() / sample_bytes;
  word available = sample_count < frame_size
      ? 0
      : (sample_count - frame_size) / hop_size + 1;
  word count = Utils::min(available, destination.length() / 4);
  for (word frame = 0; frame < count; frame++) {
    const uint8* start = source.address() + frame * hop_size * sample_bytes;
    float energy = reduce_samples(start, frame_size, sample_bytes, format,
                                  operation);
    put_float32_le(destination.address() + frame * 4, energy);
  }
  return Smi::from(count);
#endif
}

PRIMITIVE(normalized_correlation) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, signal, Blob, pattern, MutableBlob, destination, int, format);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0) FAIL(INVALID_ARGUMENT);
  word signal_count = signal.length() / sample_bytes;
  word pattern_count = pattern.length() / sample_bytes;
  if (pattern_count == 0) FAIL(INVALID_ARGUMENT);
  word available = signal_count < pattern_count
      ? 0
      : signal_count - pattern_count + 1;
  word count = Utils::min(available, destination.length() / 4);

  float pattern_sum = 0.0f;
  for (word i = 0; i < pattern_count; i++) {
    pattern_sum += normalized(read_q31(
        pattern.address() + i * sample_bytes, format));
  }
  float pattern_mean = pattern_sum / pattern_count;
  float pattern_energy = 0.0f;
  for (word i = 0; i < pattern_count; i++) {
    float centered = normalized(read_q31(
        pattern.address() + i * sample_bytes, format)) - pattern_mean;
    pattern_energy += centered * centered;
  }

  for (word offset = 0; offset < count; offset++) {
    float signal_sum = 0.0f;
    float signal_sum_of_squares = 0.0f;
    float covariance = 0.0f;
    for (word i = 0; i < pattern_count; i++) {
      float sample = normalized(read_q31(
          signal.address() + (offset + i) * sample_bytes, format));
      float pattern_centered = normalized(read_q31(
          pattern.address() + i * sample_bytes, format)) - pattern_mean;
      signal_sum += sample;
      signal_sum_of_squares += sample * sample;
      covariance += sample * pattern_centered;
    }
    float signal_energy = signal_sum_of_squares -
                          signal_sum * signal_sum / pattern_count;
    float denominator = signal_energy * pattern_energy;
    float correlation = denominator <= 0.0f
        ? 0.0f
        : covariance / std::sqrt(denominator);
    put_float32_le(destination.address() + offset * 4, correlation);
  }
  return Smi::from(count);
#endif
}

PRIMITIVE(goertzel) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, Blob, coefficients, MutableBlob, destination, int, format);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || coefficients.length() % 4 != 0) {
    FAIL(INVALID_ARGUMENT);
  }
  word coefficient_count = coefficients.length() / 4;
  if (destination.length() < coefficient_count * 4) FAIL(OUT_OF_RANGE);
  word sample_count = source.length() / sample_bytes;
  for (word frequency = 0; frequency < coefficient_count; frequency++) {
    float coefficient = read_float32_le(coefficients.address() + frequency * 4);
    float previous = 0.0f;
    float previous_2 = 0.0f;
    for (word i = 0; i < sample_count; i++) {
      float sample = normalized(read_q31(source.address() + i * sample_bytes,
                                         format));
      float current = sample + coefficient * previous - previous_2;
      previous_2 = previous;
      previous = current;
    }
    float power = previous * previous + previous_2 * previous_2 -
                  coefficient * previous * previous_2;
    put_float32_le(destination.address() + frequency * 4, power);
  }
  return Smi::from(coefficient_count);
#endif
}

#if defined(CONFIG_TOIT_AUDIO) && CONFIG_TOIT_AUDIO && \
    defined(CONFIG_TOIT_AUDIO_EXTRA) && CONFIG_TOIT_AUDIO_EXTRA

static void fft_q15(uint8* scratch,
                    const uint8* twiddles,
                    int size,
                    bool inverse) {
  int reversed = 0;
  for (int i = 1; i < size; i++) {
    int bit = size >> 1;
    while ((reversed & bit) != 0) {
      reversed ^= bit;
      bit >>= 1;
    }
    reversed ^= bit;
    if (i < reversed) {
      uint8* first = scratch + i * 4;
      uint8* second = scratch + reversed * 4;
      uint8 saved[4];
      memcpy(saved, first, 4);
      memcpy(first, second, 4);
      memcpy(second, saved, 4);
    }
  }

  for (int width = 2; width <= size; width <<= 1) {
    int half = width >> 1;
    int twiddle_step = size / width;
    for (int start = 0; start < size; start += width) {
      for (int j = 0; j < half; j++) {
        int twiddle = j * twiddle_step;
        int32 wr = read_int16_le(twiddles + twiddle * 4);
        int32 wi = read_int16_le(twiddles + twiddle * 4 + 2);
        if (inverse) wi = -wi;
        uint8* even = scratch + (start + j) * 4;
        uint8* odd = scratch + (start + j + half) * 4;
        int32 odd_real = read_int16_le(odd);
        int32 odd_imaginary = read_int16_le(odd + 2);
        int32 product_real = (wr * odd_real - wi * odd_imaginary) >> 15;
        int32 product_imaginary = (wr * odd_imaginary + wi * odd_real) >> 15;
        int32 even_real = read_int16_le(even);
        int32 even_imaginary = read_int16_le(even + 2);
        put_int16_le(even, saturate_q15((even_real + product_real) >> 1));
        put_int16_le(even + 2,
                     saturate_q15((even_imaginary + product_imaginary) >> 1));
        put_int16_le(odd, saturate_q15((even_real - product_real) >> 1));
        put_int16_le(odd + 2,
                     saturate_q15((even_imaginary - product_imaginary) >> 1));
      }
    }
  }
}

#endif  // CONFIG_TOIT_AUDIO && CONFIG_TOIT_AUDIO_EXTRA.

PRIMITIVE(real_fft_q15) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, Blob, twiddles, Blob, window, MutableBlob, scratch,
       MutableBlob, destination, int, format, int, size, bool, power);
  int sample_bytes = bytes_per_sample(format);
  word bin_count = size / 2 + 1;
  word destination_bytes = bin_count * 4;
  if (sample_bytes == 0 || size < 2 || size > 4096 ||
      !Utils::is_power_of_two(size) ||
      source.length() < size * sample_bytes || twiddles.length() != size * 2 ||
      (window.length() != 0 && window.length() != size * 2) ||
      scratch.length() < size * 4 || destination.length() < destination_bytes) {
    FAIL(INVALID_ARGUMENT);
  }

  for (int i = 0; i < size; i++) {
    int32 real = read_q31(source.address() + i * sample_bytes, format) >> 16;
    if (window.length() != 0) {
      real = (real * read_int16_le(window.address() + i * 2)) >> 15;
    }
    put_int16_le(scratch.address() + i * 4, saturate_q15(real));
    put_int16_le(scratch.address() + i * 4 + 2, 0);
  }

  fft_q15(scratch.address(), twiddles.address(), size, false);

  if (power) {
    for (word i = 0; i < bin_count; i++) {
      float real = static_cast<float>(read_int16_le(scratch.address() + i * 4)) /
                   32768.0f;
      float imaginary = static_cast<float>(read_int16_le(
          scratch.address() + i * 4 + 2)) / 32768.0f;
      put_float32_le(destination.address() + i * 4,
                     real * real + imaginary * imaginary);
    }
  } else {
    memcpy(destination.address(), scratch.address(), destination_bytes);
  }
  return Smi::from(bin_count);
#endif
}

PRIMITIVE(gcc_phat_delay) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, first, Blob, second, Blob, twiddles, MutableBlob, scratch,
       int, format, int, size, int, max_delay);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || size < 2 || size > 4096 ||
      !Utils::is_power_of_two(size) || max_delay < 0 || max_delay > size / 2 ||
      first.length() < sample_bytes || second.length() < sample_bytes ||
      twiddles.length() != size * 2 || scratch.length() < size * 8) {
    FAIL(INVALID_ARGUMENT);
  }
  word first_count = Utils::min(first.length() / sample_bytes,
                                static_cast<word>(size));
  word second_count = Utils::min(second.length() / sample_bytes,
                                 static_cast<word>(size));
  uint8* first_fft = scratch.address();
  uint8* second_fft = scratch.address() + size * 4;
  for (int i = 0; i < size; i++) {
    int32 first_sample = i < first_count
        ? read_q31(first.address() + i * sample_bytes, format) >> 16
        : 0;
    int32 second_sample = i < second_count
        ? read_q31(second.address() + i * sample_bytes, format) >> 16
        : 0;
    put_int16_le(first_fft + i * 4, saturate_q15(first_sample));
    put_int16_le(first_fft + i * 4 + 2, 0);
    put_int16_le(second_fft + i * 4, saturate_q15(second_sample));
    put_int16_le(second_fft + i * 4 + 2, 0);
  }
  fft_q15(first_fft, twiddles.address(), size, false);
  fft_q15(second_fft, twiddles.address(), size, false);

  // Cross-power spectrum: second * conjugate(first).  This convention makes a
  // positive lag mean that the second signal arrived later than the first.
  for (int i = 0; i < size; i++) {
    int64 ar = read_int16_le(first_fft + i * 4);
    int64 ai = read_int16_le(first_fft + i * 4 + 2);
    int64 br = read_int16_le(second_fft + i * 4);
    int64 bi = read_int16_le(second_fft + i * 4 + 2);
    float real = static_cast<float>(br * ar + bi * ai);
    float imaginary = static_cast<float>(bi * ar - br * ai);
    float magnitude = std::sqrt(real * real + imaginary * imaginary);
    if (magnitude == 0.0f) {
      put_int16_le(first_fft + i * 4, 0);
      put_int16_le(first_fft + i * 4 + 2, 0);
    } else {
      put_int16_le(first_fft + i * 4,
                   saturate_q15(static_cast<int32>(real * 32767.0f / magnitude)));
      put_int16_le(first_fft + i * 4 + 2,
                   saturate_q15(static_cast<int32>(imaginary * 32767.0f /
                                                   magnitude)));
    }
  }
  fft_q15(first_fft, twiddles.address(), size, true);

  int best_lag = 0;
  int16 best = read_int16_le(first_fft);
  for (int lag = -max_delay; lag <= max_delay; lag++) {
    int index = lag < 0 ? size + lag : lag;
    int16 correlation = read_int16_le(first_fft + index * 4);
    if (correlation > best) {
      best = correlation;
      best_lag = lag;
    }
  }
  return Smi::from(best_lag);
#endif
}

PRIMITIVE(fir) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, MutableBlob, destination, Blob, coefficients,
       MutableBlob, state, int, format, int, channels);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || channels <= 0 || channels > 32 ||
      coefficients.length() == 0 || coefficients.length() % 4 != 0) {
    FAIL(INVALID_ARGUMENT);
  }
  word tap_count = coefficients.length() / 4;
  if (state.length() != 4 + tap_count * channels * 4) FAIL(INVALID_ARGUMENT);
  word write_index = read_uint32_le(state.address());
  if (write_index >= tap_count) FAIL(INVALID_ARGUMENT);
  word count = Utils::min(source.length(), destination.length()) / sample_bytes;
  count -= count % channels;
  word frames = count / channels;
  uint8* history = state.address() + 4;
  for (word frame = 0; frame < frames; frame++) {
    for (int channel = 0; channel < channels; channel++) {
      word sample_index = frame * channels + channel;
      float sample = normalized(read_q31(
          source.address() + sample_index * sample_bytes, format));
      put_float32_le(history + (write_index * channels + channel) * 4, sample);
    }
    for (int channel = 0; channel < channels; channel++) {
      float output = 0.0f;
      word history_index = write_index;
      for (word tap = 0; tap < tap_count; tap++) {
        float coefficient = read_float32_le(coefficients.address() + tap * 4);
        float sample = read_float32_le(
            history + (history_index * channels + channel) * 4);
        output += coefficient * sample;
        history_index = history_index == 0 ? tap_count - 1 : history_index - 1;
      }
      word sample_index = frame * channels + channel;
      write_q31(destination.address() + sample_index * sample_bytes, format,
                normalized_to_q31(output));
    }
    write_index++;
    if (write_index == tap_count) write_index = 0;
  }
  put_uint32_le(state.address(), write_index);
  return Smi::from(count);
#endif
}

PRIMITIVE(biquad) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, MutableBlob, destination, Blob, coefficients,
       MutableBlob, state, int, format, int, channels);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || channels <= 0 || channels > 32 ||
      coefficients.length() == 0 ||
      coefficients.length() % 20 != 0 ||
      state.length() != (coefficients.length() / 20) * channels * 8) {
    FAIL(INVALID_ARGUMENT);
  }
  word count = Utils::min(source.length(), destination.length()) / sample_bytes;
  count -= count % channels;
  word section_count = coefficients.length() / 20;
  for (word sample_index = 0; sample_index < count; sample_index++) {
    word offset = sample_index * sample_bytes;
    float value = normalized(read_q31(source.address() + offset, format));
    word channel = sample_index % channels;
    for (word section = 0; section < section_count; section++) {
      const uint8* coefficient = coefficients.address() + section * 20;
      uint8* section_state = state.address() +
          (section * channels + channel) * 8;
      float b0 = read_float32_le(coefficient);
      float b1 = read_float32_le(coefficient + 4);
      float b2 = read_float32_le(coefficient + 8);
      float a1 = read_float32_le(coefficient + 12);
      float a2 = read_float32_le(coefficient + 16);
      float z1 = read_float32_le(section_state);
      float z2 = read_float32_le(section_state + 4);
      float output = b0 * value + z1;
      put_float32_le(section_state, b1 * value - a1 * output + z2);
      put_float32_le(section_state + 4, b2 * value - a2 * output);
      value = output;
    }
    write_q31(destination.address() + offset, format, normalized_to_q31(value));
  }
  return Smi::from(count);
#endif
}

PRIMITIVE(resample_linear) {
#if !defined(CONFIG_TOIT_AUDIO) || !CONFIG_TOIT_AUDIO || \
    !defined(CONFIG_TOIT_AUDIO_EXTRA) || !CONFIG_TOIT_AUDIO_EXTRA
  FAIL(UNIMPLEMENTED);
#else
  ARGS(Blob, source, MutableBlob, destination, MutableBlob, state, int, format,
       int, source_rate, int, destination_rate, int, channels, bool, last);
  int sample_bytes = bytes_per_sample(format);
  if (sample_bytes == 0 || source_rate <= 0 || destination_rate <= 0 ||
      source_rate > 1000000 || destination_rate > 1000000 ||
      channels <= 0 || channels > 32 || state.length() != 16 + channels * 4) {
    FAIL(INVALID_ARGUMENT);
  }
  word frame_bytes = sample_bytes * channels;
  word source_count = source.length() / frame_bytes;
  word destination_count = destination.length() / frame_bytes;
  word consumed = 0;
  word produced = 0;
  uint32 initialized = read_uint32_le(state.address());
  uint32 phase = read_uint32_le(state.address() + 8);

  if (initialized == 0 && source_count != 0) {
    for (int channel = 0; channel < channels; channel++) {
      int32 previous = read_q31(source.address() + channel * sample_bytes, format);
      put_uint32_le(state.address() + 16 + channel * 4,
                    static_cast<uint32>(previous));
    }
    consumed = 1;
    initialized = 1;
    phase = 0;
  }

  while (initialized == 1 && consumed < source_count) {
    while (phase < static_cast<uint32>(destination_rate)) {
      if (produced == destination_count) goto done;
      for (int channel = 0; channel < channels; channel++) {
        int32 previous = static_cast<int32>(read_uint32_le(
            state.address() + 16 + channel * 4));
        int32 current = read_q31(source.address() + consumed * frame_bytes +
                                 channel * sample_bytes, format);
        int64 difference = static_cast<int64>(current) - previous;
        int32 output = saturate_q31(previous +
            difference * phase / destination_rate);
        write_q31(destination.address() + produced * frame_bytes +
                  channel * sample_bytes, format, output);
      }
      produced++;
      phase += source_rate;
    }
    phase -= destination_rate;
    for (int channel = 0; channel < channels; channel++) {
      int32 current = read_q31(source.address() + consumed * frame_bytes +
                               channel * sample_bytes, format);
      put_uint32_le(state.address() + 16 + channel * 4,
                    static_cast<uint32>(current));
    }
    consumed++;
  }

  if (last && initialized != 0 && consumed == source_count) {
    initialized = 2;
    while (phase < static_cast<uint32>(destination_rate)) {
      if (produced == destination_count) goto done;
      for (int channel = 0; channel < channels; channel++) {
        int32 previous = static_cast<int32>(read_uint32_le(
            state.address() + 16 + channel * 4));
        write_q31(destination.address() + produced * frame_bytes +
                  channel * sample_bytes, format, previous);
      }
      produced++;
      phase += source_rate;
    }
    initialized = 0;
    phase = 0;
  }

done:
  put_uint32_le(state.address(), initialized);
  put_uint32_le(state.address() + 8, phase);
  put_uint32_le(state.address() + 12, consumed);
  return Smi::from(produced);
#endif
}

}  // namespace toit.

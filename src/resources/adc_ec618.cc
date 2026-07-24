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

#include "../top.h"

#ifdef TOIT_EC618

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

extern "C" {
  #include "adc.h"
  // hal_adc.h / hal_trim.h / bsp.h are not self-contained (dangling
  // extern "C" / heavy includes), so declare the helpers we need directly.
  uint32_t HAL_ADC_CalibrateRawCode(uint32_t input);
  void trimAdcSetGolbalVar(void);
  void delay_us(uint32_t us);
}

// trimAdcSetGolbalVar, delay_us, and the ADC_*/HAL_* helpers are exported by
// the base keep-list. A slot that needs them must link against a base that
// exports them; the base-id check rejects any other pairing.

namespace toit {

// The EC618 exposes two application ADC inputs. We number them the way the
// hardware application note does ("ADC0"/"ADC1") and map them to the chip's
// AIO channels:
//   channel 0 -> AIO3  (board "ADC0")
//   channel 1 -> AIO4  (board "ADC1")
// VBAT and the internal thermal sensor are separate channels; not exposed yet.
static const int kNumChannels = 2;

static AdcChannel_e aio_channel(int channel) {
  return channel == 0 ? ADC_CHANNEL_AIO3 : ADC_CHANNEL_AIO4;
}

// Conversion results, filled from the ADC ISR callback. The `adc` primitives
// are synchronous (start a conversion, busy-wait for the callback) and
// serialized per process, so one slot per channel is enough.
static volatile uint32_t conversion_result[kNumChannels] = {0, 0};
static volatile bool conversion_done[kNumChannels] = {false, false};

static void adc_callback_0(uint32_t result) { conversion_result[0] = result; conversion_done[0] = true; }
static void adc_callback_1(uint32_t result) { conversion_result[1] = result; conversion_done[1] = true; }

// AIO measurement ranges. `max_volts` is the largest input the range can read;
// `ratio` scales the calibrated core voltage (0..1.2 V) back up to the input
// (the higher ranges divide the input down with an internal resistor network,
// RANGE_1_2 reads the pin directly).
struct AioRange {
  float max_volts;
  AdcAioResDiv_e resdiv;
  float ratio;
};

static const AioRange ALL_RANGES[] = {
  {1.2f, ADC_AIO_RESDIV_BYPASS,         1.0f},
  {1.4f, ADC_AIO_RESDIV_RATIO_14OVER16, 16.0f / 14},
  {1.6f, ADC_AIO_RESDIV_RATIO_12OVER16, 16.0f / 12},
  {1.9f, ADC_AIO_RESDIV_RATIO_10OVER16, 16.0f / 10},
  {2.4f, ADC_AIO_RESDIV_RATIO_8OVER16,  16.0f / 8},
  {2.7f, ADC_AIO_RESDIV_RATIO_7OVER16,  16.0f / 7},
  {3.2f, ADC_AIO_RESDIV_RATIO_6OVER16,  16.0f / 6},
  {3.8f, ADC_AIO_RESDIV_RATIO_5OVER16,  16.0f / 5},
};
static const int NUM_RANGES = sizeof(ALL_RANGES) / sizeof(ALL_RANGES[0]);

// Picks the smallest range that still covers `max_volts`, for the best
// resolution. `max_volts <= 0` (unspecified) selects the widest range.
static const AioRange* select_range(double max_volts) {
  if (max_volts > 0.0) {
    for (int i = 0; i < NUM_RANGES; i++) {
      if ((double)ALL_RANGES[i].max_volts >= max_volts) return &ALL_RANGES[i];
    }
  }
  return &ALL_RANGES[NUM_RANGES - 1];  // Widest; the chip can't read above 3.8 V.
}

class AdcResource : public SimpleResource {
 public:
  TAG(AdcResource);
  AdcResource(SimpleResourceGroup* group, int channel, float ratio)
      : SimpleResource(group), channel_(channel), ratio_(ratio) {}

  int channel() const { return channel_; }
  float ratio() const { return ratio_; }

 private:
  int channel_;
  float ratio_;
};

// Poll bound that comfortably outlasts a single conversion (well under a
// millisecond): 500 polls of 10 us = 5 ms.
static const int kConversionPollLimit = 500;

// Runs one conversion on `channel`. On success stores the input voltage (volts)
// in `*out_volts` and returns true; returns false on timeout.
static bool convert_once(int channel, float ratio, double* out_volts) {
  conversion_done[channel] = false;
  ADC_startConversion(aio_channel(channel), ADC_USER_APP);
  // The conversion completes from the ADC ISR; `conversion_done` is volatile.
  for (int polls = 0; polls < kConversionPollLimit && !conversion_done[channel]; polls++) {
    delay_us(10);
  }
  if (!conversion_done[channel]) return false;
  // CalibrateRawCode returns the core ADC voltage in microvolts (0..1.2e6);
  // the range ratio scales it back to the (divided-down) input.
  uint32_t core_uv = HAL_ADC_CalibrateRawCode(conversion_result[channel]);
  *out_volts = ((double)core_uv * ratio) / 1e6;
  return true;
}

MODULE_IMPLEMENTATION(adc, MODULE_ADC)

PRIMITIVE(init) {
  ARGS(SimpleResourceGroup, group, int, channel, bool, allow_restricted, double, max);
  USE(allow_restricted);
  if (channel < 0 || channel >= kNumChannels) FAIL(INVALID_ARGUMENT);
  if (max < 0.0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  const AioRange* range = select_range(max);

  // Load the efuse ADC trim once so HAL_ADC_CalibrateRawCode uses the
  // chip's calibrated transfer curve instead of its linear fallback.
  static bool trim_loaded = false;
  if (!trim_loaded) {
    trimAdcSetGolbalVar();
    trim_loaded = true;
  }

  AdcConfig_t config;
  ADC_getDefaultConfig(&config);
  config.channelConfig.aioResDiv = range->resdiv;
  ADC_channelInit(aio_channel(channel), ADC_USER_APP, &config,
                  channel == 0 ? adc_callback_0 : adc_callback_1);

  AdcResource* resource = _new AdcResource(group, channel, range->ratio);
  if (resource == null) {
    ADC_channelDeInit(aio_channel(channel), ADC_USER_APP);
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(get) {
  ARGS(AdcResource, resource, int, samples);
  if (samples < 1 || samples > 64) FAIL(OUT_OF_RANGE);

  double sum = 0.0;
  for (int i = 0; i < samples; i++) {
    double volts;
    if (!convert_once(resource->channel(), resource->ratio(), &volts)) FAIL(HARDWARE_ERROR);
    sum += volts;
  }
  return Primitive::allocate_double(sum / samples, process);
}

PRIMITIVE(get_raw) {
  ARGS(AdcResource, resource);
  double volts;
  if (!convert_once(resource->channel(), resource->ratio(), &volts)) FAIL(HARDWARE_ERROR);
  // The raw conversion register is 12 bits.
  return Smi::from((word)(conversion_result[resource->channel()] & 0xFFF));
}

PRIMITIVE(close) {
  ARGS(AdcResource, resource);
  ADC_channelDeInit(aio_channel(resource->channel()), ADC_USER_APP);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618

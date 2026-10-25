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

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"

extern "C" {
  #include "adc.h"
  #include "cmsis_os2.h"
  // hal_adc.h / hal_trim.h / bsp.h are not self-contained (dangling
  // extern "C" / heavy includes), so declare the helpers we need directly.
  uint32_t HAL_ADC_CalibrateRawCode(uint32_t input);
  void trimAdcSetGolbalVar(void);
}

// trimAdcSetGolbalVar and the ADC_*/HAL_* helpers are exported by the base
// keep-list. A slot that needs them must link against a base that exports them;
// the base-id check rejects any other pairing.

namespace toit {

// The EC618 exposes two application ADC inputs. We number them the way the
// hardware application note does ("ADC0"/"ADC1") and map them to the chip's
// AIO channels:
//   channel 0 -> AIO3  (board "ADC0")
//   channel 1 -> AIO4  (board "ADC1")
// VBAT and the internal thermal sensor are separate channels; not exposed yet.
static const int kNumChannels = 2;
static ResourcePool<int, -1> adc_channels(0, 1);
static bool trim_loaded = false;

static AdcChannel_e aio_channel(int channel) {
  return channel == 0 ? ADC_CHANNEL_AIO3 : ADC_CHANNEL_AIO4;
}

// Callbacks may arrive after a request was canceled or its resource closed.
// Keep ISR state outside resources; never dereference a resource from the ISR.
struct AdcChannelState {
  volatile uint32_t result;
  volatile uint32_t generation;
  volatile bool in_flight;
  volatile bool done;
  volatile bool retiring;
};
static AdcChannelState channels[kNumChannels] = {};

class AdcIrqGuard {
 public:
  AdcIrqGuard() : mask_(__get_PRIMASK()) { __disable_irq(); }
  ~AdcIrqGuard() { __DSB(); __ISB(); __set_PRIMASK(mask_); }
 private:
  uint32_t mask_;
};

static void adc_callback(int channel, uint32_t result) {
  auto& state = channels[channel];
  state.result = result;
  state.done = true;
  state.in_flight = false;
  if (state.retiring) {
    // The vendor explicitly supports deinitializing from its callback. It
    // cannot remove a queued request, so close defers this until completion.
    ADC_channelDeInit(aio_channel(channel), ADC_USER_APP);
    state.done = false;
    state.retiring = false;
    return;
  }
  Ec618EventSource::send_event_from_isr(Event::adc_type(channel), state.generation);
}

static void adc_callback_0(uint32_t result) { adc_callback(0, result); }
static void adc_callback_1(uint32_t result) { adc_callback(1, result); }

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

class AdcResource : public EventResource {
 public:
  enum RequestKind {
    REQUEST_NONE,
    REQUEST_VOLTAGE,
    REQUEST_RAW,
  };

  TAG(AdcResource);
  AdcResource(ResourceGroup* group, int channel, float ratio)
      : EventResource(group, Event::adc_type(channel))
      , channel_(channel)
      , ratio_(ratio)
      , request_kind_(REQUEST_NONE)
      , requested_samples_(0)
      , remaining_samples_(0)
      , sum_(0.0)
      , deadline_us_(0) {}

  ~AdcResource() override {
    // Usually the conversion has already completed. Allow a short bounded
    // drain for close immediately after start, without holding a mutex or
    // masking interrupts. A stuck conversion quarantines the channel until
    // its callback arrives rather than giving its result to a new owner.
    int64 deadline = OS::get_monotonic_time() + 5000;
    while (channels[channel_].in_flight && OS::get_monotonic_time() < deadline) {
      osDelay(1);
    }
    {
      Locker locker(OS::global_mutex());
      AdcIrqGuard guard;
      if (channels[channel_].in_flight) {
        channels[channel_].retiring = true;
      } else {
        ADC_channelDeInit(aio_channel(channel_), ADC_USER_APP);
        channels[channel_].done = false;
      }
    }
    adc_channels.put(channel_);
  }

  int channel() const { return channel_; }
  float ratio() const { return ratio_; }

  RequestKind request_kind() const { return request_kind_; }
  int requested_samples() const { return requested_samples_; }
  int remaining_samples() const { return remaining_samples_; }
  double sum() const { return sum_; }
  int64 deadline_us() const { return deadline_us_; }
  bool conversion_started() const { return conversion_started_; }
  void set_conversion_started(bool value) { conversion_started_ = value; }

  void begin_request(RequestKind kind, int samples) {
    ASSERT(request_kind_ == REQUEST_NONE);
    request_kind_ = kind;
    requested_samples_ = samples;
    remaining_samples_ = samples;
    sum_ = 0.0;
  }

  void set_deadline(int64 deadline_us) { deadline_us_ = deadline_us; }

  void add_sample(double value) {
    ASSERT(remaining_samples_ > 0);
    sum_ += value;
    remaining_samples_--;
  }

  void reset_request() {
    request_kind_ = REQUEST_NONE;
    requested_samples_ = 0;
    remaining_samples_ = 0;
    sum_ = 0.0;
    deadline_us_ = 0;
    conversion_started_ = false;
  }

 private:
  int channel_;
  float ratio_;
  RequestKind request_kind_;
  int requested_samples_;
  int remaining_samples_;
  double sum_;
  int64 deadline_us_;
  bool conversion_started_ = false;
};

static const int64 kConversionTimeoutUs = 5000;

// The driver has no per-request abort. If a canceled conversion is still
// running, wait for its callback before submitting a fresh request. Its value
// is never used by the new request.
static bool start_conversion(AdcResource* resource) {
  resource->set_deadline(OS::get_monotonic_time() + kConversionTimeoutUs);
  AdcIrqGuard guard;
  auto& state = channels[resource->channel()];
  resource->set_conversion_started(false);
  if (state.in_flight) return true;
  state.done = false;
  state.generation++;
  state.in_flight = true;
  if (ADC_startConversion(aio_channel(resource->channel()), ADC_USER_APP) != 0) {
    state.in_flight = false;
    return false;
  }
  resource->set_conversion_started(true);
  return true;
}

enum ConversionStatus { PENDING, COMPLETED, FAILED };

static ConversionStatus poll_conversion(AdcResource* resource, uint32_t* result) {
  auto& state = channels[resource->channel()];
  if (!resource->conversion_started()) {
    if (!state.in_flight) return start_conversion(resource) ? PENDING : FAILED;
  } else if (state.done) {
    *result = state.result;
    return COMPLETED;
  }
  return OS::get_monotonic_time() > resource->deadline_us() ? FAILED : PENDING;
}

class AdcResourceGroup : public ResourceGroup {
 public:
  TAG(AdcResourceGroup);
  AdcResourceGroup(Process* process, EventSource* source) : ResourceGroup(process, source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    auto resource = static_cast<AdcResource*>(r);
    auto& channel = channels[resource->channel()];
    // Discard notifications queued before a subsequent conversion started.
    if (!channel.done || static_cast<uint32_t>(data) != channel.generation) return state;
    return state | 1;
  }
};

MODULE_IMPLEMENTATION(adc, MODULE_ADC)

PRIMITIVE(init_group) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  auto source = Ec618EventSource::instance();
  if (source == null) FAIL(ALREADY_CLOSED);
  auto group = _new AdcResourceGroup(process, source);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(cancel) {
  ARGS(AdcResource, resource);
  resource->reset_request();
  return process->null_object();
}

PRIMITIVE(init) {
  ARGS(AdcResourceGroup, group, int, channel, bool, allow_restricted, double, max);
  USE(allow_restricted);
  if (channel < 0 || channel >= kNumChannels) FAIL(INVALID_ARGUMENT);
  if (max < 0.0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (!adc_channels.take(channel)) FAIL(ALREADY_IN_USE);
  bool channel_handed_to_resource = false;
  Defer release_channel { [&] {
    if (!channel_handed_to_resource) adc_channels.put(channel);
  } };

  // A timed-out destructor can leave a retiring vendor request. Its static
  // callback releases the hardware; until then this channel must not reopen.
  if (channels[channel].retiring || channels[channel].in_flight) FAIL(ALREADY_IN_USE);

  const AioRange* range = select_range(max);

  // Load the efuse ADC trim once so HAL_ADC_CalibrateRawCode uses the
  // chip's calibrated transfer curve instead of its linear fallback.
  // ADC setup is global vendor state, so serialize initialization of the two
  // otherwise independent application channels.
  {
    Locker locker(OS::global_mutex());
    if (!trim_loaded) {
      trimAdcSetGolbalVar();
      trim_loaded = true;
    }

    AdcIrqGuard guard;
    channels[channel].done = false;
    AdcConfig_t config;
    ADC_getDefaultConfig(&config);
    config.channelConfig.aioResDiv = range->resdiv;
    if (ADC_channelInit(aio_channel(channel), ADC_USER_APP, &config,
                        channel == 0 ? adc_callback_0 : adc_callback_1) != 0) {
      FAIL(HARDWARE_ERROR);
    }
  }

  AdcResource* resource = _new AdcResource(group, channel, range->ratio);
  if (resource == null) {
    Locker locker(OS::global_mutex());
    ADC_channelDeInit(aio_channel(channel), ADC_USER_APP);
    FAIL(MALLOC_FAILED);
  }

  channel_handed_to_resource = true;
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(get) {
  ARGS(AdcResource, resource, int, samples);
  if (samples < 1 || samples > 64) FAIL(OUT_OF_RANGE);

  if (resource->request_kind() == AdcResource::REQUEST_NONE) {
    resource->begin_request(AdcResource::REQUEST_VOLTAGE, samples);
    if (!start_conversion(resource)) {
      resource->reset_request();
      FAIL(HARDWARE_ERROR);
    }
    return process->null_object();
  }
  if (resource->request_kind() != AdcResource::REQUEST_VOLTAGE ||
      resource->requested_samples() != samples) {
    FAIL(ALREADY_IN_USE);
  }

  uint32_t result;
  auto status = poll_conversion(resource, &result);
  if (status == FAILED) {
    resource->reset_request();
    FAIL(HARDWARE_ERROR);
  }
  if (status == PENDING) return process->null_object();

  // CalibrateRawCode returns the core ADC voltage in microvolts (0..1.2e6);
  // the range ratio scales it back to the (divided-down) input.
  uint32_t core_uv = HAL_ADC_CalibrateRawCode(result);
  resource->add_sample(((double)core_uv * resource->ratio()) / 1e6);
  if (resource->remaining_samples() > 0) {
    if (!start_conversion(resource)) {
      resource->reset_request();
      FAIL(HARDWARE_ERROR);
    }
    return process->null_object();
  }

  double average = resource->sum() / samples;
  resource->reset_request();
  return Primitive::allocate_double(average, process);
}

PRIMITIVE(get_raw) {
  ARGS(AdcResource, resource);

  if (resource->request_kind() == AdcResource::REQUEST_NONE) {
    resource->begin_request(AdcResource::REQUEST_RAW, 1);
    if (!start_conversion(resource)) {
      resource->reset_request();
      FAIL(HARDWARE_ERROR);
    }
    return process->null_object();
  }
  if (resource->request_kind() != AdcResource::REQUEST_RAW) FAIL(ALREADY_IN_USE);

  uint32_t result;
  auto status = poll_conversion(resource, &result);
  if (status == FAILED) {
    resource->reset_request();
    FAIL(HARDWARE_ERROR);
  }
  if (status == PENDING) return process->null_object();

  // The raw conversion register is 12 bits.
  resource->reset_request();
  return Smi::from(result & 0xFFF);
}

PRIMITIVE(close) {
  ARGS(AdcResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618

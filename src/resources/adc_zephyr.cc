// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "pins_zephyr.h"
#include <math.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/gpio.h>

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define ADC_NODE DT_PHANDLE(TOIT_PLATFORM, adc_port)

namespace toit {
// Pin routing is board data. These conversion settings currently target Nordic
// SAADC: 12-bit single-ended, internal 600 mV reference, 40 us acquisition.
BUILD_ASSERT(DT_NODE_HAS_COMPAT(ADC_NODE, nordic_nrf_saadc));
static const device* const adc = DEVICE_DT_GET(ADC_NODE);
static const int pins[] = DT_PROP(TOIT_PLATFORM, adc_pins);
static const int inputs[] = DT_PROP(TOIT_PLATFORM, adc_inputs);
BUILD_ASSERT(ARRAY_SIZE(pins) == ARRAY_SIZE(inputs));
static K_MUTEX_DEFINE(adc_mutex);

struct AdcRange {
  double maximum;
  adc_gain gain;
};
static const AdcRange ranges[] = {
  {0.15, ADC_GAIN_4}, {0.3, ADC_GAIN_2}, {0.6, ADC_GAIN_1},
  {1.2, ADC_GAIN_1_2}, {1.8, ADC_GAIN_1_3}, {2.4, ADC_GAIN_1_4},
  {3.0, ADC_GAIN_1_5}, {3.6, ADC_GAIN_1_6},
};

class AdcResource : public SimpleResource {
 public:
  TAG(AdcResource);
  AdcResource(SimpleResourceGroup* group, const AdcRange* range)
      : SimpleResource(group), range_(range) {}

  int init(int encoded) {
    int pin;
    int result = pins_.add(encoded, &pin);
    if (result) return result;
    for (unsigned i = 0; i < ARRAY_SIZE(pins); i++) {
      if (pin != pins[i]) continue;
      input_ = inputs[i];
      // Disconnect the digital input buffer and disable any previous pulls.
      return gpio_pin_configure(zephyr_gpio_port(pin), pin % 32, GPIO_DISCONNECTED);
    }
    return -EINVAL;
  }

  int read(int samples, int* sum) {
    // The driver serializes reads but not channel setup. Keep both operations
    // together, including when different Toit processes use different gains.
    k_mutex_lock(&adc_mutex, K_FOREVER);
    Defer unlock { [&] { k_mutex_unlock(&adc_mutex); } };
    adc_channel_cfg config = {};
    config.channel_id = 0;
    config.input_positive = input_;
    config.reference = ADC_REF_INTERNAL;
    config.gain = range_->gain;
    config.acquisition_time = ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 40);
    int result = adc_channel_setup(adc, &config);
    if (result) return result;

    // One synchronous native request is bounded to 64 samples. No DMA retains
    // stack memory after adc_read returns. Using one
    // slot avoids leaving closed resources selected in a later channel scan.
    int16_t buffer[64];
    adc_sequence_options options = {};
    options.extra_samplings = samples - 1;
    adc_sequence sequence = {};
    sequence.options = &options;
    sequence.channels = BIT(0);
    sequence.buffer = buffer;
    sequence.buffer_size = samples * sizeof(buffer[0]);
    sequence.resolution = 12;
    // Use simple mode (zero interval). Zephyr v4.4.1's hardware-timer path
    // bypasses calibration and signals completion twice for a one-sample
    // buffer. The leftover semaphore token can make the next read return
    // before DMA finishes. Calibrate with a separate single sample so the
    // repeated-sampling path does not recalibrate for every sample.
    if (calibrate_) {
      adc_sequence calibration = sequence;
      calibration.options = null;
      calibration.calibrate = true;
      result = adc_read(adc, &calibration);
      if (result) return result;
      calibrate_ = false;
    }
    result = adc_read(adc, &sequence);
    if (result) return result;
    *sum = 0;
    for (int i = 0; i < samples; i++) *sum += buffer[i];
    return 0;
  }
  double maximum() const { return range_->maximum; }

 private:
  ZephyrPins pins_;
  const AdcRange* range_;
  int input_ = 0;
  bool calibrate_ = true;
};

MODULE_IMPLEMENTATION(adc, MODULE_ADC)

PRIMITIVE(init) {
  ARGS(SimpleResourceGroup, group, int, pin, bool, allow_restricted, double, max);
  // Unlike ESP32 ADC2, SAADC has no separate restricted converter.
  USE(allow_restricted);
  if (!isfinite(max) || max < 0.0) FAIL(INVALID_ARGUMENT);
  if (max > 3.6) FAIL(OUT_OF_RANGE);
  if (!device_is_ready(adc)) FAIL(HARDWARE_ERROR);
  const AdcRange* range = &ranges[ARRAY_SIZE(ranges) - 1];
  if (max > 0.0) {
    for (const AdcRange& candidate : ranges) {
      if (max <= candidate.maximum) { range = &candidate; break; }
    }
  }
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  auto resource = _new AdcResource(group, range);
  if (resource == null) FAIL(MALLOC_FAILED);
  int result = resource->init(pin);
  if (result) {
    group->unregister_resource(resource);
    if (result == -EBUSY) FAIL(ALREADY_IN_USE);
    if (result == -EINVAL || result == -EPERM) FAIL(INVALID_ARGUMENT);
    return Primitive::os_error(result, process);
  }
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(get) {
  ARGS(AdcResource, resource, int, samples);
  if (samples < 1 || samples > 64) FAIL(OUT_OF_RANGE);
  int sum;
  int result = resource->read(samples, &sum);
  if (result) return Primitive::os_error(result, process);
  return Primitive::allocate_double(sum * resource->maximum() / (4096.0 * samples), process);
}

PRIMITIVE(get_raw) {
  ARGS(AdcResource, resource);
  int raw;
  int result = resource->read(1, &raw);
  if (result) return Primitive::os_error(result, process);
  return Smi::from(raw);
}

PRIMITIVE(close) {
  ARGS(AdcResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}
}  // namespace toit
#endif

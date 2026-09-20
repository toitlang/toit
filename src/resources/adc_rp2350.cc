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

#ifdef TOIT_RP2350

#include "hardware/adc.h"
#include "hardware/gpio.h"

#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

// Shared GPIO ownership is implemented by gpio_rp2350.cc. Peripherals accept
// GPIO numbers only and reserve their own pads.
bool gpio_pool_take(int pin);
void gpio_pool_put(int pin);

static const int kExternalAdcChannels = static_cast<int>(NUM_ADC_CHANNELS) - 1;
static const int kSettleSamples = 16;
static const double kReferenceVoltage = 3.3;
static const double kAdcCodeCount = 4096.0;

static_assert(NUM_ADC_CHANNELS == 5 || NUM_ADC_CHANNELS == 9,
              "unexpected RP2350 ADC input count");

static int adc_users = 0;

static bool is_adc_pin(int pin) {
  return pin >= static_cast<int>(ADC_BASE_PIN) &&
      pin < static_cast<int>(ADC_BASE_PIN) + kExternalAdcChannels;
}

class AdcResource : public SimpleResource {
 public:
  TAG(AdcResource);

  AdcResource(SimpleResourceGroup* group, int pin)
      : SimpleResource(group), pin_(pin) {}

  ~AdcResource() override {
    {
      Locker locker(OS::global_mutex());
      ASSERT(adc_users > 0);
      gpio_deinit(pin_);
      if (--adc_users == 0) {
        // The SDK has no adc_deinit. Stop conversions and turn the block off;
        // adc_init resets and enables it when the next resource is opened.
        adc_run(false);
        hw_clear_bits(&adc_hw->cs, ADC_CS_EN_BITS);
      }
    }
    gpio_pool_put(pin_);
  }

  int pin() const { return pin_; }
  int channel() const { return pin_ - static_cast<int>(ADC_BASE_PIN); }

 private:
  int pin_;
};

// Selects the resource's channel and discards conversions to settle the ADC's
// sample-and-hold after a mux change. This keeps sequential reads independent
// of the previous channel, including with a high-impedance source.
static void select_and_settle(AdcResource* resource) {
  adc_select_input(resource->channel());
  for (int i = 0; i < kSettleSamples; i++) adc_read();
}

MODULE_IMPLEMENTATION(adc, MODULE_ADC)

PRIMITIVE(init) {
  ARGS(SimpleResourceGroup, group, int, pin, bool, allow_restricted,
       double, max_voltage);
  USE(allow_restricted);
  if (max_voltage < 0.0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // Negative encodings represent the deprecated gpio.Pin API.
  if (pin < 0) FAIL(INVALID_ARGUMENT);
  if (!is_adc_pin(pin)) FAIL(OUT_OF_RANGE);
  if (!gpio_pool_take(pin)) FAIL(ALREADY_IN_USE);

  AdcResource* resource = _new AdcResource(group, pin);
  if (resource == null) {
    gpio_pool_put(pin);
    FAIL(MALLOC_FAILED);
  }

  {
    // RP2350 has one ADC shared by every input. Initialization, mux selection,
    // conversions, and shutdown are serialized on this lock.
    Locker locker(OS::global_mutex());
    if (adc_users++ == 0) adc_init();
    adc_gpio_init(pin);
  }

  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(get) {
  ARGS(AdcResource, resource, int, samples);
  if (samples < 1 || samples > 64) FAIL(OUT_OF_RANGE);

  uint32_t sum = 0;
  {
    Locker locker(OS::global_mutex());
    select_and_settle(resource);
    for (int i = 0; i < samples; i++) sum += adc_read();
  }

  double average_code = static_cast<double>(sum) / samples;
  // The SDK exposes raw 12-bit samples but no board-specific calibration.
  // Convert against the board's nominal 3.3 V ADC supply.
  double voltage = average_code * kReferenceVoltage / kAdcCodeCount;
  return Primitive::allocate_double(voltage, process);
}

PRIMITIVE(get_raw) {
  ARGS(AdcResource, resource);
  uint16_t result;
  {
    Locker locker(OS::global_mutex());
    select_and_settle(resource);
    result = adc_read();
  }
  return Smi::from(result);
}

PRIMITIVE(close) {
  ARGS(AdcResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_RP2350

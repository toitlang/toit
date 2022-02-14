// Copyright (C) 2021 Toitware ApS.
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

#ifdef TOIT_FREERTOS

#include "adc_esp32.h"

#include <driver/gpio.h>
#include <driver/adc.h>
#include <esp_adc_cal.h>

#include "../entropy_mixer.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"

#include "../event_sources/gpio_esp32.h"
#include "../event_sources/system_esp32.h"

namespace toit {

static int get_adc1_channel(int pin) {
  switch (pin) {
    case 36: return ADC1_CHANNEL_0;
    case 37: return ADC1_CHANNEL_1;
    case 38: return ADC1_CHANNEL_2;
    case 39: return ADC1_CHANNEL_3;
    case 32: return ADC1_CHANNEL_4;
#ifndef CONFIG_IDF_TARGET_ESP32C3
    case 33: return ADC1_CHANNEL_5;
    case 34: return ADC1_CHANNEL_6;
    case 35: return ADC1_CHANNEL_7;
#endif
    default: return adc1_channel_t(-1);
  }
}

static int get_adc2_channel(int pin) {
  switch (pin) {
    case 4: return ADC2_CHANNEL_0;
    default: return adc2_channel_t(-1);
  }
}

static adc_atten_t get_atten(int mv) {
  if (mv <= 1100) return ADC_ATTEN_DB_0;
  if (mv <= 1500) return ADC_ATTEN_DB_2_5;
  if (mv <= 2200) return ADC_ATTEN_DB_6;
  return ADC_ATTEN_DB_11;
}

MODULE_IMPLEMENTATION(adc, MODULE_ADC)

PRIMITIVE(init) {
  ARGS(SimpleResourceGroup, group, int, pin, double, max);

  if (max < 0.0) INVALID_ARGUMENT;

  int max_mv = static_cast<int>(max * 1000.0);
  if (max_mv == 0) max_mv = 3900;
  adc_atten_t atten = get_atten(max_mv);
  adc_unit_t unit = ADC_UNIT_MAX;

  int chan = get_adc1_channel(pin);
  if (chan >= 0) {
    unit = ADC_UNIT_1;
    esp_err_t err = adc1_config_width(ADC_WIDTH_BIT_12);
    if (err != ESP_OK) return Primitive::os_error(err, process);

    err = adc1_config_channel_atten((adc1_channel_t)chan, atten);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  } else {
    chan = get_adc2_channel(pin);
    if (chan >= 0) {
      unit = ADC_UNIT_2;
      esp_err_t err = adc2_config_channel_atten((adc2_channel_t)chan, atten);
      if (err != ESP_OK) return Primitive::os_error(err, process);
    } else {
      OUT_OF_RANGE;
    }
  }
  
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  ADCState* state = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    state = _new ADCState(group, unit, chan);
    if (!state) MALLOC_FAILED;
  }

  const int DEFAULT_VREF = 1100;
  esp_adc_cal_characterize(unit, atten, ADC_WIDTH_BIT_12, DEFAULT_VREF, &state->calibration);

  proxy->set_external_address(state);

  return proxy;
}

PRIMITIVE(get) {
  ARGS(AdcState, state, int, samples);

  uint32_t adc_reading = 0;

  // Multisampling.
  for (int i = 0; i < samples; i++) {
    if (state->unit == ADC_UNIT_1) {
      adc_reading += adc1_get_raw((adc1_channel_t)state->chan);
    } else {
      int value = 0;
      esp_err_t err = adc2_get_raw((adc2_channel_t)state->chan, ADC_WIDTH_BIT_12, &value);
      if (err != ESP_OK) return Primitive::os_error(err, process);
      adc_reading += value;
    }
  }

  adc_reading /= samples;

  // Convert adc_reading to voltage in mV.
  uint32_t voltage = esp_adc_cal_raw_to_voltage(adc_reading, &state->calibration);

  return Primitive::allocate_double(voltage / 1000.0, process);
}

PRIMITIVE(close) {
  ARGS(ByteArray, raw_state);

  delete raw_state->as_external();

  raw_state->clear_external_address();

  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS

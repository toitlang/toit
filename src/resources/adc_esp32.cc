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

#ifdef TOIT_ESP32

#include <esp_adc/adc_oneshot.h>
#include <esp_adc/adc_cali.h>
#include <esp_adc/adc_cali_scheme.h>
#include <esp_log.h>

#include "../entropy_mixer.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"

namespace toit {

#if CONFIG_IDF_TARGET_ESP32

#define ADC_CLK_SRC_DEFAULT ADC_RTC_CLK_SRC_DEFAULT

static int get_adc1_channel(int pin) {
  switch (pin) {
    case 36: return ADC_CHANNEL_0;
    case 37: return ADC_CHANNEL_1;
    case 38: return ADC_CHANNEL_2;
    case 39: return ADC_CHANNEL_3;
    case 32: return ADC_CHANNEL_4;
    case 33: return ADC_CHANNEL_5;
    case 34: return ADC_CHANNEL_6;
    case 35: return ADC_CHANNEL_7;
    default: return -1;
  }
}

static int get_adc2_channel(int pin) {
  switch (pin) {
    case 4: return ADC_CHANNEL_0;
    case 0: return ADC_CHANNEL_1;
    case 2: return ADC_CHANNEL_2;
    case 15: return ADC_CHANNEL_3;
    case 13: return ADC_CHANNEL_4;
    case 12: return ADC_CHANNEL_5;
    case 14: return ADC_CHANNEL_6;
    case 27: return ADC_CHANNEL_7;
    case 25: return ADC_CHANNEL_8;
    case 26: return ADC_CHANNEL_9;
    default: return -1;
  }
}

#elif CONFIG_IDF_TARGET_ESP32C3

#define ADC_CLK_SRC_DEFAULT ADC_DIGI_CLK_SRC_DEFAULT

static int get_adc1_channel(int pin) {
  switch (pin) {
    case 0: return ADC_CHANNEL_0;
    case 1: return ADC_CHANNEL_1;
    case 2: return ADC_CHANNEL_2;
    case 3: return ADC_CHANNEL_3;
    case 4: return ADC_CHANNEL_4;
    default: return -1;
  }
}

static int get_adc2_channel(int pin) {
  // On ESP32C3, ADC2 is no longer supported, due to its HW limitation.
  // There was an errata on the Espressif website.
  // Pin 5 is still connected to ADC2, but we don't allow to use it.
  return -1;
}

#elif CONFIG_IDF_TARGET_ESP32C6

#define ADC_CLK_SRC_DEFAULT ADC_DIGI_CLK_SRC_DEFAULT

static int get_adc1_channel(int pin) {
  switch (pin) {
    case 0: return ADC_CHANNEL_0;
    case 1: return ADC_CHANNEL_1;
    case 2: return ADC_CHANNEL_2;
    case 3: return ADC_CHANNEL_3;
    case 4: return ADC_CHANNEL_4;
    case 5: return ADC_CHANNEL_5;
    case 6: return ADC_CHANNEL_6;
    default: return -1;
  }
}

#elif CONFIG_IDF_TARGET_ESP32S2

#define ADC_CLK_SRC_DEFAULT ADC_RTC_CLK_SRC_DEFAULT
#define ADC_HAS_NO_DEFAULT_VREF 1

static int get_adc1_channel(int pin) {
  switch (pin) {
    case 1: return ADC_CHANNEL_0;
    case 2: return ADC_CHANNEL_1;
    case 3: return ADC_CHANNEL_2;
    case 4: return ADC_CHANNEL_3;
    case 5: return ADC_CHANNEL_4;
    case 6: return ADC_CHANNEL_5;
    case 7: return ADC_CHANNEL_6;
    case 8: return ADC_CHANNEL_7;
    case 9: return ADC_CHANNEL_8;
    case 10: return ADC_CHANNEL_9;
    default: return -1;
  }
}

static int get_adc2_channel(int pin) {
  switch (pin) {
    case 11: return ADC_CHANNEL_0;
    case 12: return ADC_CHANNEL_1;
    case 13: return ADC_CHANNEL_2;
    case 14: return ADC_CHANNEL_3;
    case 15: return ADC_CHANNEL_4;
    case 16: return ADC_CHANNEL_5;
    case 17: return ADC_CHANNEL_6;
    case 18: return ADC_CHANNEL_7;
    case 19: return ADC_CHANNEL_8;
    case 20: return ADC_CHANNEL_9;
    default: return -1;
  }
}

#elif CONFIG_IDF_TARGET_ESP32S3

#define ADC_CLK_SRC_DEFAULT ADC_RTC_CLK_SRC_DEFAULT

static int get_adc1_channel(int pin) {
  switch (pin) {
    case 1: return  ADC_CHANNEL_0;
    case 2: return  ADC_CHANNEL_1;
    case 3: return  ADC_CHANNEL_2;
    case 4: return  ADC_CHANNEL_3;
    case 5: return  ADC_CHANNEL_4;
    case 6: return  ADC_CHANNEL_5;
    case 7: return  ADC_CHANNEL_6;
    case 8: return  ADC_CHANNEL_7;
    case 9: return  ADC_CHANNEL_8;
    case 10: return  ADC_CHANNEL_9;
    default: return -1;
  }
}

static int get_adc2_channel(int pin) {
  switch (pin) {
    case 11: return  ADC_CHANNEL_0;
    case 12: return  ADC_CHANNEL_1;
    case 13: return  ADC_CHANNEL_2;
    case 14: return  ADC_CHANNEL_3;
    case 15: return  ADC_CHANNEL_4;
    case 16: return  ADC_CHANNEL_5;
    case 17: return  ADC_CHANNEL_6;
    case 18: return  ADC_CHANNEL_7;
    case 19: return  ADC_CHANNEL_8;
    case 20: return  ADC_CHANNEL_9;
    default: return -1;
  }
}

#else

#error "Unsupported target"
// For future targets:
// The default bitwidth can be found in 'components/hal/esp32XX/include/hal/adc_ll.h'.
// The channel mapping is described in the GPIO page of the documentation. Google
//   for 'esp32xx pins'.

#endif

static adc_atten_t get_attenuation(int mv) {
  if (mv <= 1100) return ADC_ATTEN_DB_0;
  if (mv <= 1500) return ADC_ATTEN_DB_2_5;
  if (mv <= 2200) return ADC_ATTEN_DB_6;
  return ADC_ATTEN_DB_12;
}

static adc_oneshot_unit_handle_t adc1_unit = null;
static int adc1_use_count = 0;
#if SOC_ADC_PERIPH_NUM == 2
static adc_oneshot_unit_handle_t adc2_unit = null;
static int adc2_use_count = 0;
#elif SOC_ADC_PERIPH_NUM > 2
#error "unexpected ADC peripheral count"
#endif

static void adc_use_count_from_handle(adc_oneshot_unit_handle_t* unit_handle,
                                      int** use_count,
                                      adc_unit_t* unit_id) {
  if (unit_handle == &adc1_unit) {
    *use_count = &adc1_use_count;
    *unit_id = ADC_UNIT_1;
  }
#if SOC_ADC_PERIPH_NUM > 1
  if (unit_handle == &adc2_unit) {
    *use_count = &adc2_use_count;
    *unit_id = ADC_UNIT_2;
  }
#endif
  if (*use_count == null) FATAL("unexpected ADC unit handle");
}

static esp_err_t adc_use(adc_oneshot_unit_handle_t* unit_handle) {
  { Locker locker(OS::global_mutex());
    int* use_count = null;
    adc_unit_t unit_id;
    adc_use_count_from_handle(unit_handle, &use_count, &unit_id);
    if (*use_count > 0) {
      ASSERT(*unit_handle != null);
      (*use_count)++;
      return ESP_OK;
    }
    ASSERT(*unit_handle == null);
    adc_oneshot_unit_init_cfg_t init_config = {
      .unit_id = unit_id,
      .clk_src = ADC_CLK_SRC_DEFAULT,
      .ulp_mode = ADC_ULP_MODE_DISABLE,

    };
    esp_err_t err = adc_oneshot_new_unit(&init_config, unit_handle);
    if (err == ESP_OK) {
      *use_count = 1;
    } else {
      *unit_handle = null;
    }
    return err;
  }
}

static void adc_unuse(adc_oneshot_unit_handle_t* unit_handle) {
  { Locker locker(OS::global_mutex());
    int* use_count = null;
    adc_unit_t unit_id;
    adc_use_count_from_handle(unit_handle, &use_count, &unit_id);
    (*use_count)--;
    if (*use_count == 0) {
      adc_oneshot_del_unit(*unit_handle);
      *unit_handle = null;
    }
  }
}

static esp_err_t calibration_init(adc_unit_t unit,
                                  adc_channel_t channel,
                                  adc_atten_t atten,
                                  adc_cali_handle_t* handle) {
  esp_err_t err = ESP_FAIL;

#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
  adc_cali_curve_fitting_config_t cali_config = {
    .unit_id = unit,
    .chan = channel,
    .atten = atten,
    .bitwidth = ADC_BITWIDTH_DEFAULT,
  };
  err = adc_cali_create_scheme_curve_fitting(&cali_config, handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
  adc_cali_line_fitting_config_t cali_config = {
    .unit_id = unit,
    .atten = atten,
    .bitwidth = ADC_BITWIDTH_DEFAULT,
#ifndef ADC_HAS_NO_DEFAULT_VREF
    // If the chip wasn't calibrated just use the default vref.
    .default_vref = 1100,
#endif
  };
  err = adc_cali_create_scheme_line_fitting(&cali_config, handle);
#else
// This might not be fatal. Maybe there are chips that don't support
// software calibration. In that case it should also fall back to
// no calibration.
#error "no supported calibration scheme"
#endif
  if (err != ESP_OK) *handle = null;
  return err;
}

static void calibration_deinit(adc_cali_handle_t handle) {
  if (handle == null) return;
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
  adc_cali_delete_scheme_curve_fitting(handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
  adc_cali_delete_scheme_line_fitting(handle);
#else
#error "no supported calibration scheme"
#endif
}

class AdcResource : public SimpleResource {
 public:
  TAG(AdcResource);
  AdcResource(SimpleResourceGroup* group,
              adc_oneshot_unit_handle_t* unit,
              adc_channel_t channel,
              adc_cali_handle_t calibration)
      : SimpleResource(group)
      , unit_(unit)
      , channel_(channel)
      , calibration_(calibration) {}

  virtual ~AdcResource() {
    adc_unuse(unit_);
    if (calibration_ != null) {
      calibration_deinit(calibration_);
    }
  }

  adc_oneshot_unit_handle_t* unit() const { return unit_; }
  adc_channel_t channel() const { return channel_; }
  adc_cali_handle_t calibration() const { return calibration_; }

 private:
  adc_oneshot_unit_handle_t* unit_;
  adc_channel_t channel_;
  adc_cali_handle_t calibration_;
};

MODULE_IMPLEMENTATION(adc, MODULE_ADC)

PRIMITIVE(init) {
  ARGS(SimpleResourceGroup, group, int, pin, bool, allow_restricted, double, max);

  if (max < 0.0) FAIL(INVALID_ARGUMENT);

  // Allocate the proxy early, as it is the easiest to handle when there
  // are memory issues.
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int max_mv = static_cast<int>(max * 1000.0);
  if (max_mv == 0) max_mv = 3900;
  adc_atten_t attenuation = get_attenuation(max_mv);

  adc_oneshot_unit_handle_t* unit_handle = null;
  adc_unit_t unit_id;

  int channel = get_adc1_channel(pin);
  if (channel >= 0) {
    unit_handle = &adc1_unit;
    unit_id = ADC_UNIT_1;
  }
#if SOC_ADC_PERIPH_NUM > 1
  if (channel < 0 && allow_restricted) {
    channel = get_adc2_channel(pin);
    if (channel >= 0) {
      unit_handle = &adc2_unit;
      unit_id = ADC_UNIT_2;
    }
  }
#else
  USE(allow_restricted);
#endif
  if (channel < 0) FAIL(OUT_OF_RANGE);

  bool successful_return = false;

  esp_err_t err = adc_use(unit_handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer unuse_handle { [&] { if (!successful_return) adc_unuse(unit_handle); } };

  adc_oneshot_chan_cfg_t channel_config = {
    .atten = attenuation,
    .bitwidth = ADC_BITWIDTH_DEFAULT,
  };
  err = adc_oneshot_config_channel(*unit_handle, static_cast<adc_channel_t>(channel), &channel_config);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  adc_cali_handle_t calibration = null;
  err = calibration_init(unit_id, static_cast<adc_channel_t>(channel), attenuation, &calibration);
  if (err == ESP_ERR_NOT_SUPPORTED) {
    // We have seen this for early ESP32S3 dev boards.
    ESP_LOGW("ADC", "eFuse not burned, no calibration");
  } else if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  Defer deinit_calib { [&] { if (!successful_return) calibration_deinit(calibration); } };

  AdcResource* resource = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    resource = _new AdcResource(group,
                                unit_handle,
                                static_cast<adc_channel_t>(channel),
                                calibration);
    if (!resource) FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(resource);

  successful_return = true;
  return proxy;
}

PRIMITIVE(get) {
  ARGS(AdcResource, resource, int, samples);

  if (samples < 1 || samples > 64) FAIL(OUT_OF_RANGE);

  if (resource->calibration() == null) FAIL(UNSUPPORTED);

  uint32_t adc_reading = 0;

  // Multisampling.
  for (int i = 0; i < samples; i++) {
    int raw;
    esp_err_t err = adc_oneshot_read(*resource->unit(), resource->channel(), &raw);
    if (err != ESP_OK) return Primitive::os_error(err, process);
    adc_reading += raw;
  }

  adc_reading /= samples;

  // Convert adc_reading to voltage in mV.
  int voltage;
  esp_err_t err = adc_cali_raw_to_voltage(resource->calibration(), adc_reading, &voltage);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return Primitive::allocate_double(voltage / 1000.0, process);
}

PRIMITIVE(get_raw) {
  ARGS(AdcResource, resource);
  int raw;
  esp_err_t err = adc_oneshot_read(*resource->unit(), resource->channel(), &raw);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return Smi::from(raw);
}

PRIMITIVE(close) {
  ARGS(AdcResource, resource);

  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();

  return process->null_object();
}

} // namespace toit

#endif // TOIT_ESP32

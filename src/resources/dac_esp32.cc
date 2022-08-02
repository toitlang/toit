// Copyright (C) 2022 Toitware ApS.
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

#include <driver/gpio.h>
#include <driver/dac.h>

#include "../entropy_mixer.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

namespace toit {

static constexpr int kDacMinFrequency = 130;
static constexpr int kDacMaxFrequency = 5500;

static constexpr dac_channel_t kInvalidChannel = static_cast<dac_channel_t>(-1);

#ifdef CONFIG_IDF_TARGET_ESP32

static dac_channel_t get_dac_channel(int pin) {
  switch (pin) {
    case 25: return DAC_CHANNEL_1;
    case 26: return DAC_CHANNEL_2;
    default: return kInvalidChannel;
  }
}

#elif CONFIG_IDF_TARGET_ESP32S2

static dac_channel_t get_dac_channel(int pin) {
  switch (pin) {
    case 17: return DAC_CHANNEL_1;
    case 18: return DAC_CHANNEL_2;
    default: return kInvalidChannel;
  }
}

#elif CONFIG_IDF_TARGET_ESP32C3

static dac_channel_t get_dac_channel(int pin) {
  // The ESP32-C3 does not have any DAC.
  return kInvalidChannel;
}

#elif CONFIG_IDF_TARGET_ESP32

#error "Unsupported ESP32 target"

#else

static dac_channel_t get_dac_channel(int pin) {
  return kInvalidChannel;
}

#endif

class DacResourceGroup;

static int cosine_user_count = 0;

class DacResource : public Resource {
 public:
  TAG(DacResource);
  DacResource(DacResourceGroup* group, dac_channel_t channel);

  virtual ~DacResource() override {
    unuse_cosine();
  }

  dac_channel_t channel() const { return _channel; }

  esp_err_t use_cosine();
  esp_err_t unuse_cosine();

 private:
  dac_channel_t _channel;
  bool _uses_cosine = false;
};

esp_err_t DacResource::use_cosine() {
  Locker locker(OS::resource_mutex());
  esp_err_t err = ESP_OK;
  if (_uses_cosine) return err;
  _uses_cosine = true;
  cosine_user_count++;
  if (cosine_user_count == 1) {
    // First user.
    err = dac_cw_generator_enable();
  }
  return err;
}

esp_err_t DacResource::unuse_cosine() {
  Locker locker(OS::resource_mutex());
  esp_err_t err = ESP_OK;
  if (!_uses_cosine) return err;
  _uses_cosine = false;
  cosine_user_count--;
  if (cosine_user_count == 0) {
    // Last user.
    err = dac_cw_generator_disable();
  }
  return err;
}

class DacResourceGroup : public ResourceGroup {
 public:
  TAG(DacResourceGroup);
  explicit DacResourceGroup(Process* process)
      : ResourceGroup(process) {}

  virtual void on_unregister_resource(Resource* resource) override {
    DacResource* dac_resource = static_cast<DacResource*>(resource);

    dac_output_disable(dac_resource->channel());
  }
 private:
  static int _cosine_user_count;
};

DacResource::DacResource(DacResourceGroup* group, dac_channel_t channel)
    : Resource(group), _channel(channel) {}


MODULE_IMPLEMENTATION(dac, MODULE_DAC)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  DacResourceGroup* touch = _new DacResourceGroup(process);
  if (!touch) MALLOC_FAILED;

  proxy->set_external_address(touch);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(DacResourceGroup, group, int, pin, uint8, initial_value);

  dac_channel_t channel = get_dac_channel(pin);
  if (channel == kInvalidChannel) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  DacResource* resource = _new DacResource(group, channel);
  if (resource == null) MALLOC_FAILED;

  esp_err_t err = dac_output_voltage(channel, initial_value);
  if (err != ESP_OK) {
    delete resource;
    return Primitive::os_error(err, process);
  }

  err = dac_output_enable(channel);
  if (err != ESP_OK) {
    delete resource;
    return Primitive::os_error(err, process);
  }

  group->register_resource(resource);

  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(DacResourceGroup, resource_group, DacResource, resource);

  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(set) {
  ARGS(DacResource, resource, uint8, dac_value);
  dac_channel_t channel = resource->channel();

  esp_err_t err = resource->unuse_cosine();
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = dac_output_voltage(channel, dac_value);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(cosine_wave) {
  ARGS(DacResource, resource, int, scale, int, phase, uint32, freq, int8, offset);
  dac_channel_t channel = resource->channel();

  if (scale < DAC_CW_SCALE_1 || scale > DAC_CW_SCALE_8) INVALID_ARGUMENT;
  if (phase != DAC_CW_PHASE_0 && phase != DAC_CW_PHASE_180) INVALID_ARGUMENT;
  if (freq < kDacMinFrequency || freq > kDacMaxFrequency) INVALID_ARGUMENT;

  dac_cw_config_t cw_config {
    .en_ch = channel,
    .scale = static_cast<dac_cw_scale_t>(scale),
    .phase = static_cast<dac_cw_phase_t>(phase),
    .freq = freq,
    .offset = offset,
  };
  esp_err_t err = dac_cw_generator_config(&cw_config);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = resource->use_cosine();
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS

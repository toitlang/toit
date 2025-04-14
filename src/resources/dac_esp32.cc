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

#if defined(TOIT_ESP32)

#include <soc/soc.h>

#if SOC_DAC_SUPPORTED

#include <driver/gpio.h>
#include <driver/dac_oneshot.h>
#include <driver/dac_cosine.h>

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

static ResourcePool<dac_channel_t, kInvalidChannel> dac_channels_(
  DAC_CHAN_0,
  DAC_CHAN_1
);

#if CONFIG_IDF_TARGET_ESP32

static dac_channel_t get_dac_channel(int pin) {
  switch (pin) {
    case 25: return DAC_CHAN_0;
    case 26: return DAC_CHAN_1;
    default: return kInvalidChannel;
  }
}

#elif CONFIG_IDF_TARGET_ESP32C3

#error "Unexpected DAC support for the ESP32C3"

#elif CONFIG_IDF_TARGET_ESP32C6

#error "Unexpected DAC support for the ESP32C6"

#elif CONFIG_IDF_TARGET_ESP32S2

static dac_channel_t get_dac_channel(int pin) {
  switch (pin) {
    case 17: return DAC_CHAN_0;
    case 18: return DAC_CHAN_1;
    default: return kInvalidChannel;
  }
}

#elif CONFIG_IDF_TARGET_ESP32S3

#error "Unexpected DAC support for the ESP32S3"

#else

#error "Unsupported ESP32 target"

#endif

class DacResourceGroup;

class DacResource : public Resource {
 public:
  TAG(DacResource);
  DacResource(ResourceGroup* group, dac_channel_t channel)
      : Resource(group)
      , channel_(channel) {}

  virtual ~DacResource() override;

  dac_channel_t channel() const { return channel_; }
  bool uses_cosine() const { return uses_cosine_; }

  dac_oneshot_handle_t oneshot_handle() const { return oneshot_handle_; }
  dac_cosine_handle_t cosine_handle() const { return cosine_handle_; }

  void set_oneshot_handle(dac_oneshot_handle_t handle) {
    uses_cosine_ = false;
    oneshot_handle_ = handle;
  }
  void set_cosine_handle(dac_cosine_handle_t handle) {
    uses_cosine_ = true;
    cosine_handle_ = handle;
  }

  void release_oneshot();
  void release_cosine();

 private:
  dac_channel_t channel_;
  bool uses_cosine_ = false;
  // During construction we don't allocate the oneshot/cosine handle. Instead, we
  // wait for the first output-request to allocate the corresponding handle.
  union {
    dac_oneshot_handle_t oneshot_handle_ = null;
    dac_cosine_handle_t cosine_handle_;
  };
};

DacResource::~DacResource() {
  if (uses_cosine_) {
    release_cosine();
  } else {
    release_oneshot();
  }
  dac_channels_.put(channel_);
}

void DacResource::release_oneshot() {
  ASSERT(!uses_cosine());

  auto handle = oneshot_handle_;
  if (handle != null) {
    ESP_ERROR_CHECK(dac_oneshot_del_channel(handle));
  }
  oneshot_handle_ = null;
}

void DacResource::release_cosine() {
  auto handle = cosine_handle_;
  if (handle != null) {
    dac_cosine_stop(handle);
    ESP_ERROR_CHECK(dac_cosine_del_channel(handle));
  }
  uses_cosine_ = false;
  oneshot_handle_ = null;
}

MODULE_IMPLEMENTATION(dac, MODULE_DAC)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto* group = _new SimpleResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(ResourceGroup, group, int, pin);

  dac_channel_t channel = get_dac_channel(pin);
  if (channel == kInvalidChannel) FAIL(INVALID_ARGUMENT);

  bool handed_to_resource = false;
  bool success = dac_channels_.take(channel);
  if (!success) FAIL(ALREADY_IN_USE);
  Defer put_channel { [&] { if (!handed_to_resource) dac_channels_.put(channel); } };

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  DacResource* resource = _new DacResource(group, channel);
  if (resource == null) FAIL(MALLOC_FAILED);
  handed_to_resource = true;

  group->register_resource(resource);

  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(ResourceGroup, resource_group, DacResource, resource);

  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();

  return process->null_object();
}

PRIMITIVE(set) {
  ARGS(DacResource, resource, uint8, dac_value);

  if (resource->uses_cosine()) {
    resource->release_cosine();
  }

  if (resource->oneshot_handle() == null) {
    dac_oneshot_handle_t oneshot_handle;
    dac_oneshot_config_t cfg = {
      .chan_id = resource->channel(),
    };
    esp_err_t err = dac_oneshot_new_channel(&cfg, &oneshot_handle);
    if (err != ESP_OK)  return Primitive::os_error(err, process);
    resource->set_oneshot_handle(oneshot_handle);
  }

  esp_err_t err = dac_oneshot_output_voltage(resource->oneshot_handle(), dac_value);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

static dac_cosine_atten_t scale_to_attenuation(int scale) {
  if (scale == 1) return DAC_COSINE_ATTEN_DB_0;
  if (scale == 2) return DAC_COSINE_ATTEN_DB_6;
  if (scale == 4) return DAC_COSINE_ATTEN_DB_12;
  if (scale == 8) return DAC_COSINE_ATTEN_DB_18;
  return static_cast<dac_cosine_atten_t>(-1);
}

PRIMITIVE(cosine_wave) {
  ARGS(DacResource, resource, int, scale, int, phase, uint32, freq, int8, offset);

  if (freq < kDacMinFrequency || freq > kDacMaxFrequency) FAIL(INVALID_ARGUMENT);

  if (phase != 0 && phase != 180) FAIL(INVALID_ARGUMENT);
  auto dac_phase = (phase == 0) ? DAC_COSINE_PHASE_0 : DAC_COSINE_PHASE_180;

  auto attenuation = scale_to_attenuation(scale);
  if (static_cast<int>(attenuation) == -1) FAIL(INVALID_ARGUMENT);

  if (resource->uses_cosine()) {
    // We can't modify an existing running generator. Just shut it down first.
    resource->release_cosine();
  } else {
    resource->release_oneshot();
  }

  dac_cosine_config_t cfg = {
    .chan_id = resource->channel(),
    .freq_hz = freq,
    .clk_src = DAC_COSINE_CLK_SRC_DEFAULT,
    .atten = attenuation,
    .phase = dac_phase,
    .offset = offset,
    .flags = {
      // We force the new frequency. We don't give any guarantees when multiple channels
      // use the same generator, but this seems like it's the most useful.
      .force_set_freq = true,
    },
  };
  dac_cosine_handle_t handle;
  esp_err_t err = dac_cosine_new_channel(&cfg, &handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  resource->set_cosine_handle(handle);

  err = dac_cosine_start(handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

} // namespace toit

#endif  // SOC_DAC_SUPPORTED

#endif  // TOIT_ESP32

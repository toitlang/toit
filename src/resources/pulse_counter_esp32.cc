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

#include <soc/soc_caps.h>
#include <esp_idf_version.h>

#if SOC_PCNT_SUPPORTED

#include <hal/pcnt_ll.h>
#include <driver/pulse_cnt.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#define PCNT_MAX_GLITCH_WIDTH PCNT_LL_MAX_GLITCH_WIDTH

namespace toit {

class PcntUnitResource;

class PcntUnitResource : public Resource {
 public:
  TAG(PcntUnitResource);
  PcntUnitResource(ResourceGroup* group,
                   pcnt_unit_handle_t handle)
      : Resource(group)
      , handle_(handle) {}

  ~PcntUnitResource() override {
    if (state_ == STARTED) stop();
    if (state_ != DISABLED) {
      // Setting the state to ENABLED should make things more robust.
      // It should be the default, but if the stop above didn't work,
      // then the state wasn't updated.
      state_ = ENABLED;
      disable();
    }

    for (int i = 0; i < SOC_PCNT_CHANNELS_PER_UNIT; i++) {
      if (channels_[i] == null) break;
      pcnt_del_channel(channels_[i]);
    }

    pcnt_del_unit(handle_);
  }

  pcnt_unit_handle_t handle() { return handle_; }

  bool has_channel_space() const {
    for (int i = 0; i < SOC_PCNT_CHANNELS_PER_UNIT; i++) {
      if (channels_[i] == null) return true;
    }
    return false;
  }
  void add_channel(pcnt_channel_handle_t channel) {
    ASSERT(has_channel_space());
    for (int i = 0; i < SOC_PCNT_CHANNELS_PER_UNIT; i++) {
      if (channels_[i] == null) {
        channels_[i] = channel;
        return;
      }
    }
    UNREACHABLE();
  }

  bool is_started() const { return state_ == STARTED; }

  esp_err_t enable() {
    if (state_ != DISABLED) return ESP_OK;
    esp_err_t err = pcnt_unit_enable(handle());
    if (err == ESP_OK) state_ = ENABLED;
    return err;
  }

  esp_err_t start() {
    if (state_ == STARTED) return ESP_OK;
    esp_err_t err = enable();
    if (err != ESP_OK) return err;
    err = pcnt_unit_start(handle());
    if (err == ESP_OK) state_ = STARTED;
    return err;
  }

  esp_err_t stop() {
    if (state_ != STARTED) return ESP_OK;
    esp_err_t err = pcnt_unit_stop(handle());
    if (err == ESP_OK) state_ = ENABLED;
    return err;
  }

  esp_err_t disable() {
    if (state_ == DISABLED) return ESP_OK;
    esp_err_t err = stop();
    if (err != ESP_OK) return err;
    err = pcnt_unit_disable(handle());
    if (err == ESP_OK) state_ = DISABLED;
    return err;
  }

 private:
  enum State {
    DISABLED,
    ENABLED,
    STARTED,
  };
  pcnt_unit_handle_t handle_;
  pcnt_channel_handle_t channels_[SOC_PCNT_CHANNELS_PER_UNIT] = { null, };
  State state_ = DISABLED;
};

MODULE_IMPLEMENTATION(pcnt, MODULE_PCNT)

#if defined(PCNT_LL_MIN_LIM)
// There seems to be a typo in the hal file.
// https://github.com/espressif/esp-idf/issues/15554
#error "ESP-IDF was fixed. Replace the constant below."
#endif
PRIMITIVE(new_unit) {
  ARGS(SimpleResourceGroup, resource_group,
       int, low_limit,
       int, high_limit,
       uint32, glitch_filter_ns)
  bool handed_to_resource = false;

  if (low_limit == 0) low_limit = PCNT_LL_MIN_LIN;
  if (high_limit == 0) high_limit = PCNT_LL_MAX_LIM;

  if (!(PCNT_LL_MIN_LIN <= low_limit && low_limit < 0)) FAIL(OUT_OF_RANGE);
  if (!(0 < high_limit && high_limit <= PCNT_LL_MAX_LIM)) FAIL(OUT_OF_RANGE);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  pcnt_unit_config_t config = {
    .low_limit = low_limit,
    .high_limit = high_limit,
    .intr_priority = 0,
    .flags = {
      .accum_count = 0,
    }
  };
  pcnt_unit_handle_t handle;
  esp_err_t err = pcnt_new_unit(&config, &handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer delete_unit { [&] { if (!handed_to_resource) pcnt_del_unit(handle); } };

  if (glitch_filter_ns != 0) {
    pcnt_glitch_filter_config_t glitch_config = {
      .max_glitch_ns = glitch_filter_ns,
    };
    err = pcnt_unit_set_glitch_filter(handle, &glitch_config);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  err = pcnt_unit_clear_count(handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);


  PcntUnitResource* unit = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    unit = _new PcntUnitResource(resource_group, handle);
    if (unit == null) FAIL(MALLOC_FAILED);
    resource_group->register_resource(unit);
  }
  proxy->set_external_address(unit);
  handed_to_resource = true;

  return proxy;
}

PRIMITIVE(close_unit) {
  ARGS(PcntUnitResource, unit)
  unit->resource_group()->unregister_resource(unit);
  unit_proxy->clear_external_address();
  return process->null_object();
}

static pcnt_channel_edge_action_t to_edge_action(int action) {
  switch (action) {
    case 0: return PCNT_CHANNEL_EDGE_ACTION_HOLD;
    case 1: return PCNT_CHANNEL_EDGE_ACTION_INCREASE;
    case 2: return PCNT_CHANNEL_EDGE_ACTION_DECREASE;
  }
  UNREACHABLE();
}
static bool is_valid_edge_action(int action) {
  return 0 <= action && action <= 2;
}

static pcnt_channel_level_action_t to_level_action(int action) {
  switch (action) {
    case 0: return PCNT_CHANNEL_LEVEL_ACTION_KEEP;
    case 1: return PCNT_CHANNEL_LEVEL_ACTION_INVERSE;
    case 2: return PCNT_CHANNEL_LEVEL_ACTION_HOLD;
  }
  UNREACHABLE();
}
static bool is_valid_level_action(int action) {
  return 0 <= action && action <= 2;
}

PRIMITIVE(new_channel) {
  ARGS(PcntUnitResource, unit, int, pin_number, int, on_positive_edge, int, on_negative_edge,
       int, control_pin_number, int, when_control_low, int, when_control_high)
  if (unit->is_started()) FAIL(INVALID_STATE);
  // We are only allowed to add channels when the unit is disabled.
  unit->disable();

  if (!is_valid_edge_action(on_positive_edge)) FAIL(INVALID_ARGUMENT);
  if (!is_valid_edge_action(on_negative_edge)) FAIL(INVALID_ARGUMENT);
  if (!is_valid_level_action(when_control_low)) FAIL(INVALID_ARGUMENT);
  if (!is_valid_level_action(when_control_high)) FAIL(INVALID_ARGUMENT);

  bool handed_to_unit = false;

  if (!unit->has_channel_space()) FAIL(ALREADY_IN_USE);

  pcnt_chan_config_t config {
    .edge_gpio_num = pin_number,
    .level_gpio_num = control_pin_number,
    .flags = {
      .invert_edge_input = false,
      .invert_level_input = false,
      .virt_edge_io_level = 0,
      .virt_level_io_level = 0,
      .io_loop_back = 0,
    },
  };
  pcnt_channel_handle_t handle;
  esp_err_t err = pcnt_new_channel(unit->handle(), &config, &handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer delete_channel { [&] { if (!handed_to_unit) pcnt_del_channel(handle); } };

  err = pcnt_channel_set_edge_action(handle,
                                     to_edge_action(on_positive_edge),
                                     to_edge_action(on_negative_edge));
  if (err != ESP_OK) return Primitive::os_error(err, process);

  if (control_pin_number != -1) {
    err = pcnt_channel_set_level_action(handle,
                                        to_level_action(when_control_high),
                                        to_level_action(when_control_low));
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  unit->add_channel(handle);
  handed_to_unit = true;

  return process->null_object();
}


PRIMITIVE(start) {
  ARGS(PcntUnitResource, unit)

  esp_err_t err = unit->start();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(stop) {
  ARGS(PcntUnitResource, unit)

  esp_err_t err = unit->stop();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(clear) {
  ARGS(PcntUnitResource, unit)

  esp_err_t err = pcnt_unit_clear_count(unit->handle());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(get_count) {
  ARGS(PcntUnitResource, unit)

  int value = -1;
  esp_err_t err = pcnt_unit_get_count(unit->handle(), &value);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Primitive::integer(value, process);
}

} // namespace toit

#endif // SOC_PCNT_SUPPORTED
#endif // defined(TOIT_ESP32)

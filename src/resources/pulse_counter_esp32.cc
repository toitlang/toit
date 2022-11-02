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

#if defined(TOIT_FREERTOS) && !defined(CONFIG_IDF_TARGET_ESP32C3)

#include <driver/pcnt.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

// See https://github.com/espressif/esp-idf/blob/5faf116d26d1f171b6fc422a3a8c9c0b184bc65b/components/hal/esp32/include/hal/pcnt_ll.h#L28
#define PCNT_MAX_GLITCH_WIDTH 1023

namespace toit {

const pcnt_unit_t kInvalidUnitId = static_cast<pcnt_unit_t>(-1);
const pcnt_channel_t kInvalidChannel = static_cast<pcnt_channel_t>(-1);

ResourcePool<pcnt_unit_t, kInvalidUnitId> pcnt_unit_ids(
    PCNT_UNIT_0, PCNT_UNIT_1, PCNT_UNIT_2, PCNT_UNIT_3
#if SOC_PCNT_UNIT_NUM > 4
    , PCNT_UNIT_4, PCNT_UNIT_5, PCNT_UNIT_6, PCNT_UNIT_7
#endif
);

class PcntUnitResource : public Resource {
 public:
  TAG(PcntUnitResource);
  PcntUnitResource(ResourceGroup* group, pcnt_unit_t unit_id, int16 low_limit, int16 high_limit, uint32 glitch_filter_ns)
      : Resource(group)
    , unit_id_(unit_id)
    , low_limit_(low_limit)
    , high_limit_(high_limit)
    , glitch_filter_ns_(glitch_filter_ns) {
  }

  bool is_open_channel(pcnt_channel_t channel) {
    if (channel == kInvalidChannel) return false;
    int index = static_cast<int>(channel);
    return 0 <= index && index < PCNT_CHANNEL_MAX && used_channels_[index];
  }

  esp_err_t add_channel(int pin_number,
                        pcnt_count_mode_t on_positive_edge,
                        pcnt_count_mode_t on_negative_edge,
                        int control_pin_number,
                        pcnt_ctrl_mode_t when_control_low,
                        pcnt_ctrl_mode_t when_control_high,
                        pcnt_channel_t* channel) {
    *channel = kInvalidChannel;
    // In v4.4.1 we just use a channel id.
    // https://docs.espressif.com/projects/esp-idf/en/v4.3.2/esp32/api-reference/peripherals/pcnt.html?#configuration
    // In later versions we have to call `pcnt_new_channel`.
    // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-channel
    // This static assert might hit, even though the code is still OK. Check the documentation if
    // the code from 'master' (as of 2022-07-01) has already made it into the release you are using.
    static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 4,
                  "Newer ESP-IDF might need different code");
    for (int i = 0; i < PCNT_CHANNEL_MAX; i++) {
      if (!used_channels_[i]) {
        *channel = static_cast<pcnt_channel_t>(i);
        break;
      }
    }
    if (*channel == kInvalidChannel) {
      return ESP_OK;
    }

    pcnt_config_t config {
      .pulse_gpio_num = pin_number,
      .ctrl_gpio_num = control_pin_number,
      .lctrl_mode = when_control_low,
      .hctrl_mode = when_control_high,
      .pos_mode = on_positive_edge,
      .neg_mode = on_negative_edge,
      .counter_h_lim = high_limit_,
      .counter_l_lim = low_limit_,
      .unit = unit_id_,
      .channel = *channel,
    };
    // For v4.4.1:
    // There is an error `ESP_ERR_INVALID_STATE` that could be returned by the
    // config function. Apparently one shouldn't initialize the driver multiple times.
    // However, each channel must be configured separately, so there isn't really a way
    // around that. Furthermore, the sources seem to indicate that this error is
    // never thrown.
    esp_err_t err = pcnt_unit_config(&config);
    if (err != ESP_OK) return err;

    used_channels_[static_cast<int>(*channel)] = true;

    if (glitch_filter_ns_ >= 0) {

      // The glitch-filter value should have been checked in the constructor.
      int glitch_filter_thres = APB_CLK_FREQ / 1000000 * glitch_filter_ns_ / 1000;
      pcnt_set_filter_value(unit_id_, static_cast<uint16_t>(glitch_filter_thres));
      pcnt_filter_enable(unit_id_);
    }

    // Without a call to 'clear' the unit would not start counting.
    if (!cleared_) {
      cleared_ = true;
      return pcnt_counter_clear(config.unit);
    }
    return ESP_OK;
  }

  esp_err_t close_channel(pcnt_channel_t channel) {
    ASSERT(is_open_channel(channel));
    // In v4.4.1 we should disable the channel by setting the pins to PCNT_PIN_NOT_USED.
    // https://docs.espressif.com/projects/esp-idf/en/v4.4.1/esp32/api-reference/peripherals/pcnt.html?#configuration
    // In later versions (after 4.4) we have to call `pcnt_del_channel`.
    // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-channel
    // This static assert might hit, even though the code is still OK. Check the documentation if
    // the code from 'master' (as of 2022-04-16) has already made it into the release you are using.
    static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 4,
                  "Newer ESP-IDF might need different code");
    pcnt_config_t config {
      .pulse_gpio_num = PCNT_PIN_NOT_USED,
      .ctrl_gpio_num = PCNT_PIN_NOT_USED,
      .lctrl_mode = PCNT_CHANNEL_LEVEL_ACTION_KEEP,
      .hctrl_mode = PCNT_CHANNEL_LEVEL_ACTION_KEEP,
      .pos_mode = PCNT_CHANNEL_EDGE_ACTION_HOLD,
      .neg_mode = PCNT_CHANNEL_EDGE_ACTION_HOLD,
      .counter_h_lim = 0,
      .counter_l_lim = 0,
      .unit = unit_id_,
      .channel = channel,
    };
    // TODO(florian): when should we consider the channel to be free again?
    // Probably not that important yet, but more important when we actually call `pcnt_del_channel`.
    used_channels_[static_cast<int>(channel)] = false;
    return pcnt_unit_config(&config);
  }

  void tear_down() {
    for (int i = 0; i < PCNT_CHANNEL_MAX; i++) {
      if (!used_channels_[i]) continue;
      auto channel = static_cast<pcnt_channel_t>(i);
      if (channel != kInvalidChannel) {
        // In the teardown we don't handle errors for cloning the channel.
        close_channel(channel);
      }
    }
    cleared_ = false;

    // In v4.4.1 there is no way to shut down the counter.
    // In later versions we have to call `pcnt_del_unit`.
    // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-unit
    // This static assert might hit, even though the code is still OK. Check the documentation if
    // the code from 'master' (as of 2022-07-01) has already made it into the release you are using.
    // If yes, stop the unit and the delete it.
    static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 4,
                  "Newer ESP-IDF might need different code");
  }

  // The unit id should not be exposed to the user.
  pcnt_unit_t unit_id() const { return unit_id_; }

  // Returns the APB ticks for a given glitch filter configuration.
  // The glitch filter runs on the APB clock, which generally is clocked at 80MHz.
  static int glitch_filter_ns_to_ticks(int glitch_filter_ns) {
    // The glitch-filter value should have been checked in the constructor.
    return APB_CLK_FREQ / 1000000 * glitch_filter_ns / 1000;
  }

  static bool validate_glitch_filter_ticks(int ticks) {
    return 0 < ticks && ticks <= PCNT_MAX_GLITCH_WIDTH;
  }

 private:
  pcnt_unit_t unit_id_;
  int16 low_limit_;
  int16 high_limit_;
  int glitch_filter_ns_;
  bool used_channels_[PCNT_CHANNEL_MAX] = { false, };
  bool cleared_ = false;
};

class PcntUnitResourceGroup : public ResourceGroup {
 public:
  TAG(PcntUnitResourceGroup);
  explicit PcntUnitResourceGroup(Process* process)
      : ResourceGroup(process) {}

 protected:
  virtual void on_unregister_resource(Resource* r) override {
    PcntUnitResource* unit = reinterpret_cast<PcntUnitResource*>(r);
    unit->tear_down();
  }
};

MODULE_IMPLEMENTATION(pcnt, MODULE_PCNT)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  PcntUnitResourceGroup* pcnt = _new PcntUnitResourceGroup(process);
  if (pcnt == null) MALLOC_FAILED;

  proxy->set_external_address(pcnt);
  return proxy;
}

PRIMITIVE(new_unit) {
  ARGS(PcntUnitResourceGroup, unit_resource_group, int16, low_limit, int16, high_limit, int, glitch_filter_ns)

  if (low_limit > 0 || high_limit < 0) OUT_OF_RANGE;
  if (glitch_filter_ns > 0) {
    int ticks = PcntUnitResource::glitch_filter_ns_to_ticks(glitch_filter_ns);
    if (!PcntUnitResource::validate_glitch_filter_ticks(ticks)) OUT_OF_RANGE;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  pcnt_unit_t unit_id = pcnt_unit_ids.any();
  if (unit_id == kInvalidUnitId) ALREADY_IN_USE;

  PcntUnitResource* unit = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    // Later versions (after v4.4) initialize the unit with the low and high limit.
    // Similarly, we pass in the glitch_filter_ns which, in recent versions, must be
    // set before the unit is used.
    // For now we pass it to the resource so we can create the channel with the values.
    unit = _new PcntUnitResource(unit_resource_group, unit_id, low_limit, high_limit, glitch_filter_ns);
    if (unit == null) {
      pcnt_unit_ids.put(unit_id);
      MALLOC_FAILED;
    }
  }

  // In v4.4.1 the unit is not allocated, but everything happens when a channel
  // is allocated.
  // In later versions we have to call `pcnt_new_unit`.
  // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-unit
  // This static assert might hit, even though the code is still OK. Check the documentation if
  // the code from 'master' (as of 2022-07-01) has already made it into the release you are using.
  // If yes, create a new unit.
  static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 4,
                "Newer ESP-IDF might need different code");

  proxy->set_external_address(unit);
  return proxy;
}

PRIMITIVE(close_unit) {
  ARGS(PcntUnitResource, unit)
  unit->tear_down();
  pcnt_unit_ids.put(unit->unit_id());
  unit_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(new_channel) {
  ARGS(PcntUnitResource, unit, int, pin_number, int, on_positive_edge, int, on_negative_edge,
       int, control_pin_number, int, when_control_low, int, when_control_high)
  if (on_positive_edge < 0 || on_positive_edge >= PCNT_COUNT_MAX) INVALID_ARGUMENT;
  if (on_negative_edge < 0 || on_negative_edge >= PCNT_COUNT_MAX) INVALID_ARGUMENT;
  if (when_control_low < 0 || when_control_low >= PCNT_MODE_MAX) INVALID_ARGUMENT;
  if (when_control_high < 0 || when_control_high >= PCNT_MODE_MAX) INVALID_ARGUMENT;

  pcnt_channel_t channel = kInvalidChannel;
  esp_err_t err = unit->add_channel(pin_number,
                                    static_cast<pcnt_count_mode_t>(on_positive_edge),
                                    static_cast<pcnt_count_mode_t>(on_negative_edge),
                                    control_pin_number,
                                    static_cast<pcnt_ctrl_mode_t>(when_control_low),
                                    static_cast<pcnt_ctrl_mode_t>(when_control_high),
                                    &channel);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  if (channel == kInvalidChannel) ALREADY_IN_USE;
  return Smi::from(static_cast<int>(channel));
}

PRIMITIVE(close_channel) {
  ARGS(PcntUnitResource, unit, int, channel_id)
  pcnt_channel_t channel = static_cast<pcnt_channel_t>(channel_id);
  if (!unit->is_open_channel(channel)) INVALID_ARGUMENT;
  esp_err_t err = unit->close_channel(channel);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(start) {
  ARGS(PcntUnitResource, unit)

  esp_err_t err = pcnt_counter_resume(unit->unit_id());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(stop) {
  ARGS(PcntUnitResource, unit)

  esp_err_t err = pcnt_counter_pause(unit->unit_id());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(clear) {
  ARGS(PcntUnitResource, unit)

  esp_err_t err = pcnt_counter_clear(unit->unit_id());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(get_count) {
  ARGS(PcntUnitResource, unit)

  int16 value = -1;
  esp_err_t err = pcnt_get_counter_value(unit->unit_id(), &value);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from(value);
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) && !defined(CONFIG_IDF_TARGET_ESP32C3)

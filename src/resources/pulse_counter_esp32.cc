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

#include <driver/pcnt.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"


namespace toit {

const pcnt_unit_t kInvalidUnitId = static_cast<pcnt_unit_t>(-1);
const pcnt_channel_t kInvalidChannel = static_cast<pcnt_channel_t>(-1);

ResourcePool<pcnt_unit_t, kInvalidUnitId> pcnt_unit_ids(
    PCNT_UNIT_0, PCNT_UNIT_1, PCNT_UNIT_2, PCNT_UNIT_3
#if SOC_PCNT_UNIT_NUM > 4
    , PCNT_UNIT_4, PCNT_UNIT_5, PCNT_UNIT_6, PCNT_UNIT_7
#endif
);

class PcntChannelResourceGroup : public ResourceGroup {
 public:
  TAG(PcntChannelResourceGroup);
  PcntChannelResourceGroup(Process* process, pcnt_unit_t unit)
     : ResourceGroup(process)
     , _unit(unit) { }

  pcnt_channel_t any() {
    return _pcnt_channels.any();
  }

  void put(pcnt_channel_t channel) {
    _pcnt_channels.put(channel);
  }

 protected:
  virtual void on_unregister_resource(Resource* r) override {
    // In v4.3.2 we should disable the channel by setting the pins to PCNT_PIN_NOT_USED.
    // https://docs.espressif.com/projects/esp-idf/en/v4.3.2/esp32/api-reference/peripherals/pcnt.html?#configuration
    // In later versions (after 4.4) we have to call `pcnt_del_channel`.
    // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-channel
    // This static assert might hit, even though the code is still OK. Check the documentation if
    // the code from 'master' (as of 2022-04-16) has already made it into the release you are using.
    static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 3,
                  "Newer ESP-IDF might need different code");
    pcnt_channel_t channel = static_cast<pcnt_channel_t>(static_cast<IntResource*>(r)->id());
    pcnt_config_t config {
      .pulse_gpio_num = PCNT_PIN_NOT_USED,
      .ctrl_gpio_num = PCNT_PIN_NOT_USED,
      .unit = _unit,
      .channel = channel,
    };
    pcnt_unit_config(&config);
    _pcnt_channels.put(channel);
  }

 private:
  pcnt_unit_t _unit;
  ResourcePool<pcnt_channel_t, kInvalidChannel> _pcnt_channels = ResourcePool<pcnt_channel_t, kInvalidChannel>(
    PCNT_CHANNEL_0, PCNT_CHANNEL_1
  );
};

class PcntUnitResource : public Resource {
 public:
  TAG(PcntUnitResource);
  PcntUnitResource(ResourceGroup* group, pcnt_unit_t unit_id, int16 low_limit, int16 high_limit)
    : Resource(group)
    , _unit_id(unit_id)
    , _low_limit(low_limit)
    , _high_limit(high_limit)
    , _channel_resource_group(group->process(), unit_id) {
  }

  void tear_down() {
    _channel_resource_group.tear_down();
    // In v4.3.2 there is no way to shut down the counter.
    // In later versions we have to call `pcnt_del_unit`.
    // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-unit
    // This static assert might hit, even though the code is still OK. Check the documentation if
    // the code from 'master' (as of 2022-04-16) has already made it into the release you are using.
    // If yes, stop the unit and the delete it.
    static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 3,
                  "Newer ESP-IDF might need different code");
  }

  // The unit id should not be exposed to the user.
  pcnt_unit_t unit_id() { return _unit_id; }

  // The limits could be exposed to the user, but the framework doesn't
  // give any way to read these values, so they would need to be stored by Toit.
  int16 low_limit() const { return _low_limit; }
  int16 high_limit() const { return _high_limit; }
  PcntChannelResourceGroup* channel_resource_group() { return &_channel_resource_group; }

 private:
  pcnt_unit_t _unit_id;
  int16 _low_limit;
  int16 _high_limit;
  PcntChannelResourceGroup _channel_resource_group;
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
  ARGS(PcntUnitResourceGroup, unit_resource_group, uint16, low_limit, int16, high_limit)

  if (low_limit > 0 || high_limit < 0) OUT_OF_RANGE;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  pcnt_unit_t unit_id = pcnt_unit_ids.any();
  if (unit_id == kInvalidUnitId) ALREADY_IN_USE;

  PcntUnitResource* unit = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    // Later versions (v4.4+) initialize the unit with the low and high limit.
    // For now we pass it to the resource so we can create the channel with the values.
    unit = _new PcntUnitResource(unit_resource_group, unit_id, low_limit, high_limit);
    if (unit == null) {
      pcnt_unit_ids.put(unit_id);
      MALLOC_FAILED;
    }
  }

  // In v4.3.2 the unit is not allocated, but everything happens when a channel
  // is allocated.
  // In later versions we have to call `pcnt_new_unit`.
  // https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/pcnt.html#install-pcnt-unit
  // This static assert might hit, even though the code is still OK. Check the documentation if
  // the code from 'master' (as of 2022-04-16) has already made it into the release you are using.
  // If yes, create a new unit.
  static_assert(ESP_IDF_VERSION_MAJOR == 4 && ESP_IDF_VERSION_MINOR == 3,
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
  ARGS(PcntUnitResource, unit, int, pin_number)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto channel_resource_group = unit->channel_resource_group();

  pcnt_channel_t channel = channel_resource_group->any();
  if (channel == kInvalidChannel) ALREADY_IN_USE;
  bool successful = false;
  // TODO(florian): not allowed to use 'new', and thus `std::function`.
  // Defer put_if_unsuccessful { [&]() { if (!successful) channel_resource_group->put(channel); } };

  // Don't call `channel_resource_group->register_id`, as we don't want the
  // tear-down functions to be called as long as we haven't done the
  // hardware calls.
  IntResource* resource = _new IntResource(channel_resource_group, channel);
  if (resource == null) MALLOC_FAILED;

  proxy->set_external_address(resource);

  pcnt_config_t config {
    .pulse_gpio_num = pin_number,
    .ctrl_gpio_num = PCNT_PIN_NOT_USED,
    .lctrl_mode = PCNT_MODE_KEEP,
    .hctrl_mode = PCNT_MODE_KEEP,
    .pos_mode = PCNT_COUNT_INC,
    .neg_mode = PCNT_COUNT_DIS,
    .counter_h_lim = unit->high_limit(),
    .counter_l_lim = unit->low_limit(),
    .unit = unit->unit_id(),
    .channel = channel,
  };
  // For v4.3.2:
  // There is an error `ESP_ERR_INVALID_STATE` that could be returned by the
  // config function. Apparently one shouldn't initialize the driver multiple times.
  // However, each channel must be configured separately, so there isn't really a way
  // around that. Furthermore, the sources seem to indicate that this error is
  // never thrown.
  esp_err_t err = pcnt_unit_config(&config);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  // Without a call to 'clear' the unit would not start counting.
  pcnt_counter_clear(config.unit);

  successful = true;  // So we don't put the channel_id back into the pool.
  channel_resource_group->register_resource(resource);
  return proxy;
}

PRIMITIVE(close_channel) {
  ARGS(PcntUnitResource, unit, IntResource, channel_resource)
  auto group = unit->channel_resource_group();
  group->unregister_id(channel_resource->id());
  channel_resource_proxy->clear_external_address();
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

#endif // TOIT_FREERTOS

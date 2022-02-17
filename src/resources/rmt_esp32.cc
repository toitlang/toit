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
#include "../primitive.h"
#include "../resource.h"
#include "../resource_pool.h"

#include "driver/rmt.h"

namespace toit {



ResourcePool<int, -1> rmt_channels(
    RMT_CHANNEL_0, RMT_CHANNEL_1, RMT_CHANNEL_2, RMT_CHANNEL_3,
    RMT_CHANNEL_4, RMT_CHANNEL_5, RMT_CHANNEL_6, RMT_CHANNEL_7
);

class RMTResourceGRoup : public ResourceGroup {
 public:
  TAG(RMTResourceGroup);
  explicit RMTResourceGroup(Process* process)
    : ResourceGroup(process, GPIOEventSource::instance()) {}

  virtual void on_unregister_resource(Resource* r) {
    rmt_channel_t channel = static_cast<rmt_channel_t>(static_cast<IntResource*(r)->id());
    rmt_uninstall_driver(channel);
    rmt_channels.put(channel);
    // TODO uninstall driver

  }

 private:
  virtual uint32_t on_event(Resource* resource, word data, uint32_t state) {

  }
}

MODULE_IMPLEMENTATION(MODULE_RMT)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  RMTResourceGroup* rmt = _new RMTResourceGroup(process);
  if (!rmt) MALLOC_FAILED;

  proxy->set_external_address(rmt);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(RMTResourceGroup, resource_group, int, channel_num)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (!rmt_channels.take(channel_num)) ALREADY_IN_USE;

  // TODO install RMT driver for channel.
  IntResource* resource = resource_group->register_id(channel_num);
  if (!resource) {
    rmt_channels.take(put)
    MALLOC_FAILED;
  }
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(RMTResourceGroup, resource_group,  IntResource, resource)

  int channel = resource->id();
  resource_group->unregister_id(channel);
  resource_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(config) {
  ARGS(int, pin_num, int, channel_num, bool, rx, bool, tx int, mem_block_num)
  if (rx == tx || mem_block_num < 2) INVALID_ARGUMENT;

  rmt_config_t config = rx ? RMT_DEFAULT_CONFIG_RX(pin_num, channel_num) : RMT_DEFAULT_CONFIG_TX(pin_num, channel_num);
  config.mem_block_num = mem_block_num;

  // TODO: Allow additional paramters

  esp_err_t err = rmt_config(&config);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  err = rmt_install_driver(channel_number, 0, 0);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
} // namespace toit

PRIMITIVE(receive) {

}

PRIMITIVE(transmit) {

}

#endif // TOIT_FREERTOS

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

#include "driver/rmt.h"

#include "../primitive.h"
#include "../resource.h"
#include "../resource_pool.h"

namespace toit {


ResourcePool<int, -1> rmt_channels(
    RMT_CHANNEL_0, RMT_CHANNEL_1, RMT_CHANNEL_2, RMT_CHANNEL_3,
    RMT_CHANNEL_4, RMT_CHANNEL_5, RMT_CHANNEL_6, RMT_CHANNEL_7
);

class RMTResourceGroup : public ResourceGroup {
 public:
  TAG(RMTResourceGroup);
  RMTResourceGroup(Process* process)
    : ResourceGroup(process, null) { }

  virtual void on_unregister_resource(Resource* r) {
    rmt_channel_t channel = static_cast<rmt_channel_t>(static_cast<IntResource*>(r)->id());
    rmt_driver_uninstall(channel);
    rmt_channels.put(channel);
  }

};


MODULE_IMPLEMENTATION(rmt, MODULE_RMT)

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
  ARGS(RMTResourceGroup, resource_group, IntResource, resource)

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
}

PRIMITIVE(read) {
  ARGS(int, rx_num)

  return process->program()->null_object();
}

PRIMITIVE(transfer) {
  ARGS(int, tx_num, Blob, blob)

  if (item_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  rmt_item32_t* items = reinterpret_cast<rmt_item32_t*>(items_bytes);

  esp_err_t err = rmt_write_items(tx_num, items, items_bytes.length() / 4, true);

  if ( err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(transfer_and_read) {
  ARGS(int, tx_num, int, rx_num, Blob, items_bytes)

  return process->program()->null_object();
}

} // namespace toit
#endif // TOIT_FREERTOS

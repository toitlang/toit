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

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
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


MODULE_IMPLEMENTATION(rmt, MODULE_RMT);

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

  // TODO install RMT driver for channel?
  IntResource* resource = resource_group->register_id(channel_num);
  if (!resource) {
    rmt_channels.put(channel_num);
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
  ARGS(int, pin_num, int, channel_num, bool, is_tx, int, mem_block_num)
  if (mem_block_num < 2) INVALID_ARGUMENT;

  // TODO: is there a better way to initialize this?
  rmt_config_t config = { };
  config.mem_block_num = mem_block_num;
  config.channel = (rmt_channel_t) channel_num;
  config.gpio_num = (gpio_num_t) pin_num;
  // TODO: Allow additional paramters
  config.clk_div = 80;
  config.flags = 0;
  config.rmt_mode = is_tx ? RMT_MODE_TX : RMT_MODE_RX;
  if (is_tx) {
    rmt_tx_config_t tx_config = { 0 };
    tx_config.carrier_freq_hz = 38000;
    tx_config.carrier_level = RMT_CARRIER_LEVEL_HIGH;
    tx_config.idle_level = RMT_IDLE_LEVEL_LOW;
    tx_config.carrier_duty_percent = 33;
    tx_config.carrier_en = false;
    tx_config.loop_en = false;
    tx_config.idle_output_en = true;
    config.tx_config = tx_config;
  } else {
    rmt_rx_config_t rx_config = { 0 };
    rx_config.idle_threshold = 12000;
    rx_config.filter_ticks_thresh = 100;
    rx_config.filter_en = true;
    config.rx_config = rx_config;
  }

  esp_err_t err = rmt_config(&config);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  err = rmt_driver_install((rmt_channel_t) channel_num, 0, 0);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(transfer) {
  ARGS(int, tx_num, Blob, items_bytes)

  if (items_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  rmt_item32_t* items = reinterpret_cast<rmt_item32_t*>(const_cast<uint8*>(items_bytes.address()));

  esp_err_t err = rmt_write_items((rmt_channel_t) tx_num, items, items_bytes.length() / 4, true);

  if ( err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(transfer_and_read) {
  ARGS(int, tx_num, int, rx_num, Blob, items_bytes, int, max_output_len)

  if (items_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  Error* error = null;
  ByteArray* data = process->allocate_byte_array(max_output_len, &error, /*force_external*/ true);
  if (data == null) return error;

  rmt_item32_t* items = reinterpret_cast<rmt_item32_t*>(const_cast<uint8*>(items_bytes.address()));
  rmt_channel_t rx_channel = (rmt_channel_t) rx_num;

  RingbufHandle_t rb = NULL;
  esp_err_t err = rmt_get_ringbuf_handle(rx_channel, &rb);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  rmt_rx_start(rx_channel, true);
  err = rmt_write_items((rmt_channel_t) tx_num, items, items_bytes.length() / 4, true);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  size_t length = 0;
  // TODO how many ticks should we actually wait?
  void* received_items = xRingbufferReceive(rb, &length, 400);

  // TODO check whether length corresponds to rmt_item32_t?

  ByteArray::Bytes bytes(data);
  memcpy(bytes.address(), received_items, length);
  vRingbufferReturnItem(rb, received_items);
  rmt_rx_stop(rx_channel);
  data->resize_external(process, length);

  return process->program()->null_object();
}


} // namespace toit
#endif // TOIT_FREERTOS

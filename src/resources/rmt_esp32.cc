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


// HELPER
esp_err_t configure(const rmt_config_t* config, rmt_channel_t channel_num, size_t rx_buffer_size, Process* process) {
  esp_err_t err = rmt_config(config);
  if (ESP_OK != err) return err;

  err = rmt_set_source_clk(channel_num, RMT_BASECLK_APB);
  if (ESP_OK != err) return err;

  err = rmt_driver_install((rmt_channel_t) channel_num, rx_buffer_size, 0);
  if (ESP_OK != err) return err;
  return err;
}

PRIMITIVE(config_tx) {
  ARGS(int, pin_num, int, channel_num, int, mem_block_num, int, clk_div, int, flags,
       bool, carrier_en, int, carrier_freq_hz, int, carrier_level, int, carrier_duty_percent,
       bool, loop_en, bool, idle_output_en, int, idle_level)

  // TODO: is there a better way to initialize this?
  rmt_config_t config = { };

  config.gpio_num = (gpio_num_t) pin_num;
  config.channel = (rmt_channel_t) channel_num;
  config.mem_block_num = mem_block_num;
  config.clk_div = clk_div;
  config.flags = flags;
  config.rmt_mode = RMT_MODE_TX;
  rmt_tx_config_t tx_config = { 0 };
  tx_config.carrier_en = carrier_en;
  tx_config.carrier_freq_hz = carrier_freq_hz;
  tx_config.carrier_level = (rmt_carrier_level_t) carrier_level;
  tx_config.carrier_duty_percent = carrier_duty_percent;
  tx_config.loop_en = loop_en;
  tx_config.idle_output_en = idle_output_en;
  tx_config.idle_level = (rmt_idle_level_t) idle_level;
  config.tx_config = tx_config;

  esp_err_t err = configure(&config, (rmt_channel_t) channel_num, 0, process);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(config_rx) {
  ARGS(int, pin_num, int, channel_num, int, mem_block_num, int, clk_div, int, flags,
       int, idle_threshold, bool, filter_en, int, filter_ticks_thresh)

  // TODO: is there a better way to initialize this?
  rmt_config_t config = { };

  config.gpio_num = (gpio_num_t) pin_num;
  config.channel = (rmt_channel_t) channel_num;
  config.mem_block_num = mem_block_num;
  config.clk_div = clk_div;
  config.flags = flags;
  config.rmt_mode = RMT_MODE_RX;
  rmt_rx_config_t rx_config = { 0 };
  rx_config.idle_threshold = idle_threshold;
  rx_config.filter_en = filter_en;
  rx_config.filter_ticks_thresh = filter_ticks_thresh;
  config.rx_config = rx_config;

  esp_err_t err = configure(&config,(rmt_channel_t) channel_num, 1000, process);
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
  printf("begin\n");
  if (items_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  printf("allocate\n");
  Error* error = null;
  // Force external, so we can adjust the length after the read.
  ByteArray* data = process->allocate_byte_array(max_output_len, &error, true);
  if (data == null) return error;

  printf("get them items\n");
  const rmt_item32_t* items = reinterpret_cast<const rmt_item32_t*>(items_bytes.address());
  printf("dur0: %d val0: %d dur1: %d val1: %d\n", items[0].duration0, items[0].level0, items[0].duration1, items[0].level1);
  rmt_channel_t rx_channel = (rmt_channel_t) rx_num;

  printf("give me buffer\n");
  RingbufHandle_t rb = NULL;
  esp_err_t err = rmt_get_ringbuf_handle(rx_channel, &rb);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  printf("start read\n");
  err = rmt_rx_start(rx_channel, true);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  printf("write (len %d)\n", items_bytes.length() / 4);
  err = rmt_write_items((rmt_channel_t) tx_num, items, items_bytes.length() / 4, true);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  size_t length = 0;

  // TODO how many ticks should we actually wait?
  printf("get items\n");
  void* received_bytes = xRingbufferReceive(rb, &length, 5000);

  printf("length: %d\n", length);
  // TODO remove this before commit:
  rmt_item32_t* received_items = reinterpret_cast<rmt_item32_t*>(received_bytes);
  if (length > 0) {
    printf("received item... dur0: %d val0: %d dur1: %d val1: %d\n", received_items[0].duration0, received_items[0].level0, received_items[0].duration1, received_items[0].level1);

    printf("prepare result\n");
    ByteArray::Bytes bytes(data);
    memcpy(bytes.address(), received_bytes, length);
    printf("return buffer\n");
    vRingbufferReturnItem(rb, received_bytes);

  }

  // TODO check whether length corresponds to rmt_item32_t?

  printf("stop reading\n");
  // TODO check error?
  rmt_rx_stop(rx_channel);
  data->resize_external(process, length);

  return data;
}


} // namespace toit
#endif // TOIT_FREERTOS

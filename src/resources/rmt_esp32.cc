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
#include "driver/gpio.h"

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
    rmt_channel_status_result_t channel_status;
    rmt_get_channel_status(&channel_status);
    if (channel_status.status[channel] != RMT_CHANNEL_UNINIT) rmt_driver_uninstall(channel);
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

esp_err_t configure(const rmt_config_t* config, rmt_channel_t channel_num, size_t rx_buffer_size, Process* process) {
  rmt_channel_status_result_t channel_status;
  esp_err_t err = rmt_get_channel_status(&channel_status);
  if (ESP_OK != err) return err;

  if (channel_status.status[channel_num] != RMT_CHANNEL_UNINIT) {
    err = rmt_driver_uninstall(channel_num);
    if (ESP_OK != err) return err;
  }

  err = rmt_config(config);
  if (ESP_OK != err) return err;

  err = rmt_set_source_clk(channel_num, RMT_BASECLK_APB);
  if (ESP_OK != err) return err;

  err = rmt_driver_install(channel_num, rx_buffer_size, 0);
  return err;
}

PRIMITIVE(config_tx) {
  ARGS(int, pin_num, int, channel_num, int, mem_block_num, int, clk_div, int, flags,
       bool, carrier_en, int, carrier_freq_hz, int, carrier_level, int, carrier_duty_percent,
       bool, loop_en, bool, idle_output_en, int, idle_level)

  rmt_config_t config = RMT_DEFAULT_CONFIG_TX(static_cast<gpio_num_t>(pin_num), static_cast<rmt_channel_t>(channel_num));

  config.mem_block_num = mem_block_num;
  config.clk_div = clk_div;
  config.flags = flags;
  config.rmt_mode = RMT_MODE_TX;
  config.tx_config.carrier_en = carrier_en;
  config.tx_config.carrier_freq_hz = carrier_freq_hz;
  config.tx_config.carrier_level = static_cast<rmt_carrier_level_t>(carrier_level);
  config.tx_config.carrier_duty_percent = carrier_duty_percent;
  config.tx_config.loop_en = loop_en;
  config.tx_config.idle_output_en = idle_output_en;
  config.tx_config.idle_level = static_cast<rmt_idle_level_t>(idle_level);

  esp_err_t err = configure(&config, static_cast<rmt_channel_t>(channel_num), 0, process);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(config_rx) {
  ARGS(int, pin_num, int, channel_num, int, mem_block_num, int, clk_div, int, flags,
       int, idle_threshold, bool, filter_en, int, filter_ticks_thresh, int, rx_buffer_size)

  rmt_config_t config = RMT_DEFAULT_CONFIG_RX(static_cast<gpio_num_t>(pin_num), static_cast<rmt_channel_t>(channel_num));

  config.mem_block_num = mem_block_num;
  config.clk_div = clk_div;
  config.flags = flags;
  config.rmt_mode = RMT_MODE_RX;
  config.rx_config.idle_threshold = idle_threshold;
  config.rx_config.filter_en = filter_en;
  config.rx_config.filter_ticks_thresh = filter_ticks_thresh;

  esp_err_t err = configure(&config,static_cast<rmt_channel_t>(channel_num), rx_buffer_size, process);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(config_bidirectional_pin) {
  ARGS(int, pin, int, tx);

  // Set open collector?
  if (pin < 32) {
      GPIO.enable_w1ts = (0x1 << pin);
  } else {
      GPIO.enable1_w1ts.data = (0x1 << (pin - 32));
  }

  rmt_set_pin(static_cast<rmt_channel_t>(tx), RMT_MODE_TX, static_cast<gpio_num_t>(pin));

  PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);

  GPIO.pin[pin].pad_driver = 1;

  return process->program()->null_object();
}

PRIMITIVE(transfer) {
  ARGS(int, tx_num, Blob, items_bytes)
  if (items_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  const rmt_item32_t* items = reinterpret_cast<const rmt_item32_t*>(items_bytes.address());
  esp_err_t err = rmt_write_items(static_cast<rmt_channel_t>(tx_num), items, items_bytes.length() / 4, true);
  if ( err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

void flush_buffer(RingbufHandle_t rb) {
  void* bytes = null;
  size_t length = 0;
  while((bytes = xRingbufferReceive(rb, &length, 0))) {
    vRingbufferReturnItem(rb, bytes);
  }
}

PRIMITIVE(transfer_and_read) {
  ARGS(int, tx_num, int, rx_num, Blob, items_bytes, int, max_output_len)
  if (items_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  Error* error = null;
  // Force external, so we can adjust the length after the read.
  ByteArray* data = process->allocate_byte_array(max_output_len, &error, true);
  if (data == null) return error;

  const rmt_item32_t* items = reinterpret_cast<const rmt_item32_t*>(items_bytes.address());
  rmt_channel_t rx_channel = (rmt_channel_t) rx_num;

  RingbufHandle_t rb = null;
  esp_err_t err = rmt_get_ringbuf_handle(rx_channel, &rb);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  flush_buffer(rb);

  err = rmt_rx_start(rx_channel, true);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = rmt_write_items(static_cast<rmt_channel_t>(tx_num), items, items_bytes.length() / 4, true);
  if (err != ESP_OK) {
    rmt_rx_stop(rx_channel);
    return Primitive::os_error(err, process);
  }

  size_t length = 0;
  // TODO add the final wait as a parameter (send the idle threshold).
  void* received_bytes = xRingbufferReceive(rb, &length, 3000);
  if (received_bytes != null) {
    if (length <= max_output_len) {
      ByteArray::Bytes bytes(data);
      memcpy(bytes.address(), received_bytes, length);
      vRingbufferReturnItem(rb, received_bytes);
    } else {
      vRingbufferReturnItem(rb, received_bytes);
      rmt_rx_stop(rx_channel);
      data->resize_external(process, 0);
      OUT_OF_RANGE;
    }
  }

  rmt_rx_stop(rx_channel);
  data->resize_external(process, length);

  return data;
}


} // namespace toit
#endif // TOIT_FREERTOS

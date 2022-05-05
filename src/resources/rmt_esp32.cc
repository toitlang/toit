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

const rmt_channel_t kInvalidChannel = static_cast<rmt_channel_t>(-1);

ResourcePool<rmt_channel_t, kInvalidChannel> rmt_channels(
    RMT_CHANNEL_0, RMT_CHANNEL_1, RMT_CHANNEL_2, RMT_CHANNEL_3
#if SOC_RMT_CHANNELS_NUM > 4
    , RMT_CHANNEL_4, RMT_CHANNEL_5, RMT_CHANNEL_6, RMT_CHANNEL_7
#endif
);

class RMTResource : public Resource {
 public:
  TAG(RMTResource);
  RMTResource(ResourceGroup* group, rmt_channel_t channel, int memory_block_count)
      : Resource(group)
      , _channel(channel)
      , _memory_block_count(memory_block_count) {}

  rmt_channel_t channel() const { return _channel; }
  int memory_block_count() const { return _memory_block_count; }

 private:
  rmt_channel_t _channel;
  int _memory_block_count;
};

class RMTResourceGroup : public ResourceGroup {
 public:
  TAG(RMTResourceGroup);
  RMTResourceGroup(Process* process)
    : ResourceGroup(process, null) { }

  virtual void on_unregister_resource(Resource* r) override {
    RMTResource* rmt_resource = static_cast<RMTResource*>(r);
    rmt_channel_t channel = rmt_resource->channel();
    rmt_channel_status_result_t channel_status;
    rmt_get_channel_status(&channel_status);
    if (channel_status.status[channel] != RMT_CHANNEL_UNINIT) rmt_driver_uninstall(channel);
    for (int i = 0; i < rmt_resource->memory_block_count(); i++) {
      rmt_channels.put(static_cast<rmt_channel_t>(channel + i));
    }
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

PRIMITIVE(channel_new) {
  ARGS(RMTResourceGroup, resource_group, int, memory_block_count, int, channel_num)
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  if (memory_block_count <= 0) INVALID_ARGUMENT;

  rmt_channel_t channel = kInvalidChannel;

  if (channel_num == -1 && memory_block_count == 1) {
    channel = rmt_channels.any();
  } else if (memory_block_count == 1) {
    channel = static_cast<rmt_channel_t>(channel_num);
    if (!rmt_channels.take(channel)) channel = kInvalidChannel;
  } else {
    // Try to find adjacent channels that are still free.
    int current_start_id = (channel_num == -1) ? 0 : channel_num;
    while (current_start_id + memory_block_count <= SOC_RMT_CHANNELS_NUM) {
      int taken = 0;
      for (int i = 0; i < memory_block_count; i++) {
        bool succeeded = rmt_channels.take(static_cast<rmt_channel_t>(current_start_id + i));
        if (!succeeded) break;
        taken++;
      }
      if (taken == memory_block_count) {
        // Success. We have reserved channels that are next to each other.
        channel = static_cast<rmt_channel_t>(current_start_id);
        break;
      } else {
        // Release all the channels we have reserved, and then try at a later
        // position.
        for (int i = 0; i < taken; i++) {
          rmt_channels.put(static_cast<rmt_channel_t>(current_start_id + i));
        }
        if (channel_num == -1) {
          // Continue searching after the current failure.
          current_start_id += taken + 1;
        } else {
          // Failure. Couldn't allocate the requested memory blocks at this position.
          break;
        }
      }
    }
  }
  if (channel == kInvalidChannel) ALREADY_IN_USE;

  RMTResource* resource = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    resource = _new RMTResource(resource_group, channel, memory_block_count);
    if (!resource) {
      for (int i = 0; i < memory_block_count; i++) {
        rmt_channels.put(static_cast<rmt_channel_t>(channel + i));
      }
      MALLOC_FAILED;
    }
  }

  resource_group->register_resource(resource);

  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(channel_delete) {
  ARGS(RMTResourceGroup, resource_group, RMTResource, resource)
  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->program()->null_object();
}

esp_err_t configure(const rmt_config_t* config, rmt_channel_t channel_num, size_t rx_buffer_size) {
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
  ARGS(RMTResource, resource, int, pin_num, uint8, clk_div, int, flags,
       bool, carrier_en, uint32, carrier_freq_hz, int, carrier_level, int, carrier_duty_percent,
       bool, loop_en, bool, idle_output_en, int, idle_level)

  if (carrier_en && carrier_level != 0 && carrier_level != 1) INVALID_ARGUMENT;
  if (carrier_duty_percent < 0 || carrier_duty_percent > 100) INVALID_ARGUMENT;
  if (idle_output_en && idle_level != 0 && idle_level != 1) INVALID_ARGUMENT;

  rmt_channel_t channel = resource->channel();
  rmt_config_t config = RMT_DEFAULT_CONFIG_TX(static_cast<gpio_num_t>(pin_num), channel);

  config.mem_block_num = resource->memory_block_count();
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

  esp_err_t err = configure(&config, channel, 0);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(config_rx) {
  ARGS(RMTResource, resource, int, pin_num, uint8, clk_div, int, flags,
       uint16, idle_threshold, bool, filter_en, uint8, filter_ticks_thresh, int, buffer_size)

  rmt_channel_t channel = resource->channel();
  rmt_config_t config = RMT_DEFAULT_CONFIG_RX(static_cast<gpio_num_t>(pin_num), channel);

  const int kMemoryBlockSize = 256;
  if (buffer_size == -1) {
    buffer_size = 2 * resource->memory_block_count() * kMemoryBlockSize;
  }
  config.mem_block_num = resource->memory_block_count();
  config.clk_div = clk_div;
  config.flags = flags;
  config.rmt_mode = RMT_MODE_RX;
  config.rx_config.idle_threshold = idle_threshold;
  config.rx_config.filter_en = filter_en;
  config.rx_config.filter_ticks_thresh = filter_ticks_thresh;

  esp_err_t err = configure(&config, channel, buffer_size);
  if (ESP_OK != err) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(get_idle_threshold) {
  ARGS(RMTResource, resource)
  uint16_t threshold;
  esp_err_t err = rmt_get_rx_idle_thresh(resource->channel(), &threshold);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from(threshold);
}

PRIMITIVE(set_idle_threshold) {
  ARGS(RMTResource, resource, uint16, threshold)
  esp_err_t err = rmt_set_rx_idle_thresh(resource->channel(), threshold);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(config_bidirectional_pin) {
  ARGS(int, pin, RMTResource, resource);

  // Set open collector?
  if (pin < 32) {
    GPIO.enable_w1ts = (0x1 << pin);
  } else {
    GPIO.enable1_w1ts.data = (0x1 << (pin - 32));
  }
  rmt_set_pin(resource->channel(), RMT_MODE_TX, static_cast<gpio_num_t>(pin));
  PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);
  GPIO.pin[pin].pad_driver = 1;

  return process->program()->null_object();
}

PRIMITIVE(transmit) {
  ARGS(RMTResource, resource, Blob, items_bytes)
  if (items_bytes.length() % 4 != 0) INVALID_ARGUMENT;

  // We are going to pass a pointer to a C function which will consume it, while we
  // yield back to the Toit VM. There could be GCs while the C function uses the memory.
  // As such, we need an external address.
  const uint8* address = items_bytes.address();
  Object* keep_alive = _raw_items_bytes;
  if (_raw_items_bytes->is_byte_array() && ByteArray::cast(_raw_items_bytes)->has_external_address()) {
    // Nothing to do. We already have an external address.
  } else {
    // Create an external byte array with the same size.
    // We will return it to the caller, so they can keep it alive.
    Error* error = null;
    // Force external.
    ByteArray* external_copy = process->allocate_byte_array(items_bytes.length(), &error, true);
    if (external_copy == null) return error;
    ByteArray::Bytes bytes(external_copy);
    memcpy(bytes.address(), address, items_bytes.length());
    address = bytes.address();
    keep_alive = external_copy;
  }

  rmt_channel_t channel = resource->channel();
  const rmt_item32_t* items = reinterpret_cast<const rmt_item32_t*>(address);
  bool wait_until_done;  // Local for naming argument in call.
  esp_err_t err = rmt_write_items(channel, items, items_bytes.length() / 4, (wait_until_done=false));
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return keep_alive;
}

PRIMITIVE(transmit_done) {
  ARGS(RMTResource, resource, ByteArray, keep_alive)
  USE(keep_alive);
  esp_err_t err = rmt_wait_tx_done(resource->channel(), 0);
  if (err == ESP_ERR_TIMEOUT) return BOOL(false);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return BOOL(true);
}

static void flush_buffer(RingbufHandle_t rb) {
  void* bytes = null;
  size_t length = 0;
  while((bytes = xRingbufferReceive(rb, &length, 0))) {
    vRingbufferReturnItem(rb, bytes);
  }
}

PRIMITIVE(start_receive) {
  ARGS(RMTResource, resource, bool, flush)

  if (flush) {
    RingbufHandle_t rb = null;
    esp_err_t err = rmt_get_ringbuf_handle(resource->channel(), &rb);
    if (err != ESP_OK) return Primitive::os_error(err, process);
    flush_buffer(rb);
  }

  bool reset_memory;
  esp_err_t err = rmt_rx_start(resource->channel(), reset_memory=flush);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(prepare_receive) {
  ARGS(RMTResource, resource)

  RingbufHandle_t rb = null;
  esp_err_t err = rmt_get_ringbuf_handle(resource->channel(), &rb);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  size_t max_size = xRingbufferGetMaxItemSize(rb);

  Error* error = null;
  // Force external, so we can adjust the length after the read.
  ByteArray* data = process->allocate_byte_array(static_cast<int>(max_size), &error, true);
  if (data == null) return error;
  return data;
}

PRIMITIVE(receive) {
  // If resize is true, then we expect that the output array was allocated in prepare_receive.
  // As such it is an external byte array that we can resize.
  ARGS(RMTResource, resource, ByteArray, output, bool, resize)

  RingbufHandle_t rb = null;
  esp_err_t err = rmt_get_ringbuf_handle(resource->channel(), &rb);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  size_t received_length;
  auto received_bytes = xRingbufferReceive(rb, &received_length, 0);
  if (received_bytes == null) return process->program()->null_object();
  if (received_length == 0) {
    // We got a 0-length item. The RMT sometimes does this. Ignore it.
    vRingbufferReturnItem(rb, received_bytes);
    return process->program()->null_object();
  }

  ByteArray::Bytes bytes(output);
  int min_length = bytes.length();
  if (received_length < min_length) min_length = received_length;

  memcpy(bytes.address(), received_bytes, min_length);
  vRingbufferReturnItem(rb, received_bytes);

  if (resize && output->has_external_address()) {
    output->resize_external(process, min_length);
  }
  return output;
}

PRIMITIVE(stop_receive) {
  ARGS(RMTResource, resource)
  esp_err_t err = rmt_rx_stop(resource->channel());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

} // namespace toit
#endif // TOIT_FREERTOS

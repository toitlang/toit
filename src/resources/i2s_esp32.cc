// Copyright (C) 2021 Toitware ApS.
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

#ifdef TOIT_ESP32

#include <driver/i2s_std.h>
#include <esp_log.h>
#include "freertos/FreeRTOS.h"
#include <freertos/queue.h>
#include <rom/ets_sys.h>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"
#include "../event_sources/ev_queue_esp32.h"

namespace toit {

const i2s_port_t kInvalidPort = i2s_port_t(-1);

const int kReadState = 1 << 0;
const int kWriteState = 1 << 1;
const int kErrorState = 1 << 2;

class I2sResourceGroup : public ResourceGroup {
 public:
  TAG(I2sResourceGroup);

  I2sResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) {
    if (data == kReadState || data == kWriteState || data == kErrorState) {
      state |= data;
    }
    return state;
  }
};

class I2sResource: public EventQueueResource {
 public:
  enum State {
    UNITIALIZED,
    STOPPED,
    STARTED,
  };

  TAG(I2sResource);
  I2sResource(I2sResourceGroup* group,
              i2s_chan_handle_t tx_handle,
              i2s_chan_handle_t rx_handle,
              QueueHandle_t queue)
    : EventQueueResource(group, queue)
    , tx_handle_(tx_handle)
    , rx_handle_(rx_handle) {
    spinlock_initialize(&spinlock_);
  }

  ~I2sResource() override {
    if (tx_handle_ != null) {
      if (state_ == STARTED) i2s_channel_disable(tx_handle_);
      i2s_del_channel(tx_handle_);
    }
    if (rx_handle_ != null) {
      if (state_ == STARTED) i2s_channel_disable(rx_handle_);
      i2s_del_channel(rx_handle_);
    }
    // The queue must be deleted after the channels have been deleted.
    // Otherwise there might still be interrupts using the queue before.
    vQueueDelete(queue());
  }

  i2s_chan_handle_t tx_handle() const { return tx_handle_; }
  i2s_chan_handle_t rx_handle() const { return rx_handle_; }

  word take_pending_event() {
    portENTER_CRITICAL(&spinlock_);
    word result = pending_event_;
    pending_event_ = 0;
    portEXIT_CRITICAL(&spinlock_);
    return result;
  }

  void adjust_pending_event(word event_type) {
    portENTER_CRITICAL(&spinlock_);
    pending_event_ |= event_type;
    portEXIT_CRITICAL(&spinlock_);
  }

  void set_state(State new_state) { state_ = new_state; }
  State state() const { return state_; }

  bool receive_event(word* data) override;

  int errors_underrun() const {
    portENTER_CRITICAL(&spinlock_);
    int result = errors_underrun_;
    portEXIT_CRITICAL(&spinlock_);
    return result;
  }

  int errors_overrun() const {
    portENTER_CRITICAL(&spinlock_);
    int result = errors_overrun_;
    portEXIT_CRITICAL(&spinlock_);
    return result;
  }

  void inc_errors_underrun() {
    portENTER_CRITICAL(&spinlock_);
    errors_underrun_++;
    portEXIT_CRITICAL(&spinlock_);
  }

  void inc_errors_overrun() {
    portENTER_CRITICAL(&spinlock_);
    errors_overrun_++;
    portEXIT_CRITICAL(&spinlock_);
  }

  bool has_reported_underrun() const {
    return error_state_ & TX_UNDERRUN_REPORTED_;
  }

  bool has_reported_overrun() const {
    return error_state_ & RX_OVERRUN_REPORTED_;
  }

  void set_has_reported_underrun() {
    error_state_ |= TX_UNDERRUN_REPORTED_;
  }

  void set_has_reported_overrun() {
    error_state_ |= RX_OVERRUN_REPORTED_;
  }

 private:
  static const int RX_OVERRUN_REPORTED_ = 1 << 0;
  static const int TX_UNDERRUN_REPORTED_ = 1 << 1;

  i2s_chan_handle_t tx_handle_;
  i2s_chan_handle_t rx_handle_;
  mutable spinlock_t spinlock_;
  word pending_event_ = 0;
  State state_ = UNITIALIZED;
  int64 errors_underrun_ = 0;
  int64 errors_overrun_ = 0;
  int error_state_ = 0;
};

bool I2sResource::receive_event(word* data) {
  word unused;
  bool more = xQueueReceive(queue(), &unused, 0);
  if (more) *data = take_pending_event();
  return more;
}

MODULE_IMPLEMENTATION(i2s, MODULE_I2S);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2sResourceGroup* i2s = _new I2sResourceGroup(process, EventQueueEventSource::instance());
  if (!i2s) {
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(i2s);
  return proxy;
}

IRAM_ATTR static bool channel_send(I2sResource* resource) {
  auto queue = resource->queue();
  BaseType_t higher_was_woken;
  word payload = 0;  // The value isn't used.
  // We don't use the return value of the queue-send.
  // If it fails, it's probably because the queue was full, and we don't
  // need to handle that case since we already changed the pending event in
  // the resource.
  xQueueSendFromISR(queue, &payload, &higher_was_woken);
  return higher_was_woken == pdTRUE;
}

IRAM_ATTR static bool channel_sent_handler(i2s_chan_handle_t handle,
                                           i2s_event_data_t* event,
                                           void* user_ctx) {
  auto resource = reinterpret_cast<I2sResource*>(user_ctx);
  resource->adjust_pending_event(kWriteState);
  return channel_send(resource);
}

IRAM_ATTR static bool channel_read_handler(i2s_chan_handle_t handle,
                                 i2s_event_data_t* event,
                                 void* user_ctx) {
  auto resource = reinterpret_cast<I2sResource*>(user_ctx);
  resource->adjust_pending_event(kReadState);
  return channel_send(resource);
}

IRAM_ATTR static bool channel_overrun_error_handler(i2s_chan_handle_t handle,
                                                     i2s_event_data_t* event,
                                                     void* user_ctx) {
  auto resource = reinterpret_cast<I2sResource*>(user_ctx);
  resource->inc_errors_overrun();
  resource->adjust_pending_event(kErrorState);
  return channel_send(resource);
}

IRAM_ATTR static bool channel_underrun_error_handler(i2s_chan_handle_t handle,
                                                      i2s_event_data_t* event,
                                                      void* user_ctx) {
  auto resource = reinterpret_cast<I2sResource*>(user_ctx);
  resource->inc_errors_underrun();
  resource->adjust_pending_event(kErrorState);
  return channel_send(resource);
}

PRIMITIVE(create) {
  ARGS(I2sResourceGroup, group,
       int, tx_pin,
       int, rx_pin,
       bool, is_master);
  esp_err_t err;
  bool handed_to_resource = false;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // We need to allocate the resource in internal memory. Otherwise it's not ISR safe.
  const int caps_flags = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  auto resource_memory = heap_caps_malloc(sizeof(I2sResource), caps_flags);
  if (!resource_memory) FAIL(MALLOC_FAILED);
  Defer free_resource_memory { [&] { if (!handed_to_resource) free(resource_memory); } };

  // No need for a big queue. The handlers change the pending-event in the
  // resource, so dropping events in the queue is fine.
  QueueHandle_t queue = xQueueCreate(1, sizeof(word));
  if (queue == null) FAIL(MALLOC_FAILED);
  Defer free_queue { [&] { if (!handed_to_resource) vQueueDelete(queue); } };

  i2s_role_t role = is_master ? I2S_ROLE_MASTER : I2S_ROLE_SLAVE;

  i2s_chan_config_t channel_config = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, role);
  i2s_chan_handle_t tx_handle = null;
  i2s_chan_handle_t rx_handle = null;
  if (tx_pin != -1 && rx_pin != -1) {
    // Duplex mode.
    err = i2s_new_channel(&channel_config, &tx_handle, &rx_handle);
  } else if (tx_pin != -1) {
    // Simplex transmit.
    err = i2s_new_channel(&channel_config, &tx_handle, null);
  } else {
    // Simplex receive.
    err = i2s_new_channel(&channel_config, null, &rx_handle);
  }
  if (err == ESP_ERR_NOT_FOUND) {
    // We use the esp-idf resource counting to check whether there are still
    // free I2S peripherals.
    // We don't want to do this ourselves, as some platforms allow to have
    // multiple simplex channels on the same controller.
    FAIL(OUT_OF_RANGE);
  }
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer del_tx_channel { [&] { if (!handed_to_resource && tx_handle != null) i2s_del_channel(tx_handle); } };
  Defer del_rx_channel { [&] { if (!handed_to_resource && rx_handle != null) i2s_del_channel(rx_handle); } };

  bool successful_return = false;

  I2sResource* resource = new (resource_memory) I2sResource(group, tx_handle, rx_handle, queue);
  // From now on, it's the resource that is responsible for releasing resources.
  handed_to_resource = true;
  // We are going to do a "delete" on the memory that was allocated with malloc, but
  // there isn't really a good way around that.
  Defer free_resource { [&] { if (!successful_return) delete resource; } };

  if (tx_handle != null) {
    i2s_event_callbacks_t callbacks = {
      .on_recv = null,
      .on_recv_q_ovf = null,
      .on_sent = &channel_sent_handler,
      .on_send_q_ovf = &channel_underrun_error_handler,
    };
    err = i2s_channel_register_event_callback(tx_handle, &callbacks, resource);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
  if (rx_handle != null) {
    i2s_event_callbacks_t callbacks = {
      .on_recv = &channel_read_handler,
      .on_recv_q_ovf = &channel_overrun_error_handler,
      .on_sent = null,
      .on_send_q_ovf = null,
    };
    err = i2s_channel_register_event_callback(rx_handle, &callbacks, resource);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);

  successful_return = true;

  return proxy;
}

PRIMITIVE(configure) {
  ARGS(I2sResource, resource,
       uint32, sample_rate,
       int, bits_per_sample,
       int, toit_mclk_multiplier,
       int, external_frequency,
       int, format,
       int, slots_in,
       int, slots_out,
       int, tx_pin,
       int, rx_pin,
       int, mclk_pin,
       int, sck_pin,
       int, ws_pin);
  esp_err_t err;

  auto state = resource->state();
  if (state == I2sResource::STARTED) FAIL(INVALID_STATE);

  if (bits_per_sample != 8 && bits_per_sample != 16 && bits_per_sample != 24 && bits_per_sample != 32) FAIL(INVALID_ARGUMENT);

  i2s_mclk_multiple_t mclk_multiple;
  switch (toit_mclk_multiplier) {
    case 128: mclk_multiple = I2S_MCLK_MULTIPLE_128; break;
    case 256: mclk_multiple = I2S_MCLK_MULTIPLE_256; break;
    case 384: mclk_multiple = I2S_MCLK_MULTIPLE_384; break;
    case 512: mclk_multiple = I2S_MCLK_MULTIPLE_512; break;
    case 576: mclk_multiple = I2S_MCLK_MULTIPLE_576; break;
    case 768: mclk_multiple = I2S_MCLK_MULTIPLE_768; break;
    case 1024:mclk_multiple = I2S_MCLK_MULTIPLE_1024; break;
    case 1152:mclk_multiple = I2S_MCLK_MULTIPLE_1152; break;
    default: FAIL(INVALID_ARGUMENT);
  }

  if (format < 0 || format > 2) FAIL(INVALID_ARGUMENT);
  if (slots_in != 0 && slots_in != 4 && slots_in != 5) FAIL(INVALID_ARGUMENT);
  if (slots_out < 0 || slots_out > 5) FAIL(INVALID_ARGUMENT);

  bool sck_inv = (sck_pin & 0x10000) != 0;
  sck_pin &= ~0x10000;
  bool ws_inv = (ws_pin & 0x10000) != 0;
  ws_pin &= ~0x10000;
  bool mclk_inv = (mclk_pin & 0x10000) != 0;
  mclk_pin &= ~0x10000;
  bool mclk_is_input = external_frequency > 0;
#ifndef SOC_I2S_HW_VERSION_2
  if (mclk_is_input) FAIL(INVALID_ARGUMENT);
#endif

  i2s_data_bit_width_t bit_width;
  switch (bits_per_sample) {
    case 8: bit_width = I2S_DATA_BIT_WIDTH_8BIT; break;
    case 16: bit_width = I2S_DATA_BIT_WIDTH_16BIT; break;
    case 24: bit_width = I2S_DATA_BIT_WIDTH_24BIT; break;
    case 32: bit_width = I2S_DATA_BIT_WIDTH_32BIT; break;
    default: UNREACHABLE();
  }

  for (int i = 0; i < 2; i++) {
    i2s_chan_handle_t handle = i == 0 ? resource->tx_handle() : resource->rx_handle();
    if (handle == null) continue;

    int slots = i == 0 ? slots_out : slots_in;

    i2s_slot_mode_t mono_or_stereo = slots < 3 ? I2S_SLOT_MODE_STEREO : I2S_SLOT_MODE_MONO;

    i2s_std_config_t std_cfg = {
      .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate),
      // The slot-cfg might be overridden later.
      .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(bit_width, mono_or_stereo),
      .gpio_cfg = {
        .mclk = mclk_pin >= 0 ? static_cast<gpio_num_t>(mclk_pin) : I2S_GPIO_UNUSED,
        .bclk = sck_pin >= 0 ? static_cast<gpio_num_t>(sck_pin): I2S_GPIO_UNUSED,
        .ws = ws_pin >= 0 ? static_cast<gpio_num_t>(ws_pin): I2S_GPIO_UNUSED,
        .dout = tx_pin >= 0 ? static_cast<gpio_num_t>(tx_pin): I2S_GPIO_UNUSED,
        .din = rx_pin >= 0 ? static_cast<gpio_num_t>(rx_pin): I2S_GPIO_UNUSED,
        .invert_flags = {
          .mclk_inv = mclk_inv,
          .bclk_inv = sck_inv,
          .ws_inv = ws_inv,
        },
      },
    };

#ifdef SOC_I2S_HW_VERSION_2
    if (mclk_is_input) std_cfg.clk_cfg.clk_src = I2S_CLK_SRC_EXTERNAL;
    std_cfg.clk_cfg.ext_clk_freq_hz = static_cast<uint32>(external_frequency);
#endif
    std_cfg.clk_cfg.mclk_multiple = mclk_multiple;

    switch (format) {
      case 0:  // Philips.
        break;

      case 1:  // MSB
        std_cfg.slot_cfg = I2S_STD_MSB_SLOT_DEFAULT_CONFIG(bit_width, mono_or_stereo);
        break;

      case 2:  // PCM-Short.
        std_cfg.slot_cfg = I2S_STD_PCM_SLOT_DEFAULT_CONFIG(bit_width, mono_or_stereo);
        break;

      default: UNREACHABLE();
    }

    switch (slots) {
      case 0:  // Stereo both.
      case 3:  // Mono both.
        std_cfg.slot_cfg.slot_mask = I2S_STD_SLOT_BOTH;
        break;
      case 1:  // Stereo left.
      case 4:  // Mono left.
        std_cfg.slot_cfg.slot_mask = I2S_STD_SLOT_LEFT;
        break;
      case 2:  // Stereo right.
      case 5:  // Mono right.
        std_cfg.slot_cfg.slot_mask = I2S_STD_SLOT_RIGHT;
        break;
    }

    if (state == I2sResource::UNITIALIZED) {
      err = i2s_channel_init_std_mode(handle, &std_cfg);
      if (err != ESP_OK) return Primitive::os_error(err, process);
    } else {
      err = i2s_channel_reconfig_std_clock(handle, &std_cfg.clk_cfg);
      if (err != ESP_OK) return Primitive::os_error(err, process);
      err = i2s_channel_reconfig_std_slot(handle, &std_cfg.slot_cfg);
      if (err != ESP_OK) return Primitive::os_error(err, process);
      err = i2s_channel_reconfig_std_gpio(handle, &std_cfg.gpio_cfg);
      if (err != ESP_OK) return Primitive::os_error(err, process);
    }
  }
  resource->set_state(I2sResource::STOPPED);

  return process->null_object();
}

PRIMITIVE(start) {
  ARGS(I2sResource, resource);
  if (resource->state() != I2sResource::STOPPED) FAIL(INVALID_STATE);

  esp_err_t err;
  auto tx_handle = resource->tx_handle();
  auto rx_handle = resource->rx_handle();
  // We enable the RX first, since that makes testing easier, as we might
  // use the same controller for receiving and sending.
  if (rx_handle != null) {
    err = i2s_channel_enable(rx_handle);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
  if (tx_handle != null) {
    err = i2s_channel_enable(tx_handle);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
  resource->set_state(I2sResource::STARTED);

  return process->null_object();
}

PRIMITIVE(stop) {
  ARGS(I2sResource, resource);
  if (resource->state() != I2sResource::STARTED) {
    return process->null_object();
  }

  esp_err_t err;
  auto tx_handle = resource->tx_handle();
  auto rx_handle = resource->rx_handle();
  if (rx_handle != null) {
    err = i2s_channel_disable(rx_handle);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
  if (tx_handle != null) {
    err = i2s_channel_disable(tx_handle);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
  resource->set_state(I2sResource::STOPPED);

  return process->null_object();
}

PRIMITIVE(preload) {
  ARGS(I2sResource, resource, Blob, buffer);
  if (resource->state() != I2sResource::STOPPED) FAIL(INVALID_STATE);

  auto tx_handle = resource->tx_handle();
  if (tx_handle == null) FAIL(UNSUPPORTED);

  size_t loaded = 0;
  esp_err_t err = i2s_channel_preload_data(tx_handle, buffer.address(), buffer.length(), &loaded);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return Smi::from(static_cast<word>(loaded));
}

PRIMITIVE(close) {
  ARGS(I2sResourceGroup, group, I2sResource, i2s);
  group->unregister_resource(i2s);
  i2s_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(write) {
  ARGS(I2sResource, resource, Blob, buffer);

#ifdef CONFIG_TOIT_REPORT_I2S_DATA_LOSS
  if (!resource->has_reported_underrun() && resource->errors_underrun() > 0) {
    resource->set_has_reported_underrun();
    ESP_LOGE("i2s", "i2s underrun detected; no further warnings will be issued");
  }
#endif

  auto tx_handle = resource->tx_handle();
  if (tx_handle == null) FAIL(UNSUPPORTED);
  size_t written = 0;
  esp_err_t err = i2s_channel_write(tx_handle, buffer.address(), buffer.length(), &written, 0);
  if (err != ESP_OK && err != ESP_ERR_TIMEOUT) {
    return Primitive::os_error(err, process);
  }

  return Smi::from(static_cast<word>(written));
}

PRIMITIVE(read_to_buffer) {
  ARGS(I2sResource, resource, MutableBlob, buffer);

#ifdef CONFIG_TOIT_REPORT_I2S_DATA_LOSS
  if (!resource->has_reported_overrun() && resource->errors_overrun() > 0) {
    resource->set_has_reported_overrun();
    ESP_LOGE("i2s", "i2s overrun detected; no further warnings will be issued");
  }
#endif

  auto rx_handle = resource->rx_handle();
  if (rx_handle == null) FAIL(UNSUPPORTED);

  size_t read = 0;
  esp_err_t err = i2s_channel_read(rx_handle, buffer.address(), buffer.length(), &read, 0);
  if (err != ESP_OK && err != ESP_ERR_TIMEOUT) return Primitive::os_error(err, process);

  return Smi::from(static_cast<word>(read));
}

PRIMITIVE(errors_underrun) {
  ARGS(I2sResource, resource);
  return Primitive::integer(resource->errors_underrun(), process);
}

PRIMITIVE(errors_overrun) {
  ARGS(I2sResource, resource);
  return Primitive::integer(resource->errors_overrun(), process);
}

} // namespace toit

#endif // TOIT_ESP32

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

#ifdef TOIT_FREERTOS

#include <driver/i2s.h>

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

ResourcePool<i2s_port_t, kInvalidPort> i2s_ports(
    I2S_NUM_0
#ifndef CONFIG_IDF_TARGET_ESP32C3
    , I2S_NUM_1
#endif
);

class I2SResourceGroup : public ResourceGroup {
 public:
  TAG(I2SResourceGroup);

  I2SResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) {
    switch (data) {
      case I2S_EVENT_RX_DONE:
        state |= kReadState;
        break;

      case I2S_EVENT_TX_DONE:
        state |= kWriteState;
        break;

      case I2S_EVENT_DMA_ERROR:
        state |= kErrorState;
        break;
    }

    return state;
  }
};

class I2SResource: public EventQueueResource {
 public:
  TAG(I2SResource);
  I2SResource(I2SResourceGroup* group, i2s_port_t port, int alignment, QueueHandle_t queue)
    : EventQueueResource(group, queue)
    , _port(port)
    , _alignment(alignment) { }

  ~I2SResource() override {
    SystemEventSource::instance()->run([&]() -> void {
      FATAL_IF_NOT_ESP_OK(i2s_driver_uninstall(_port));
    });
    i2s_ports.put(_port);
  }

  i2s_port_t port() const { return _port; }
  int alignment() const { return _alignment; }

  bool receive_event(word* data) override;

 private:
  i2s_port_t _port;
  int _alignment;
};

bool I2SResource::receive_event(word* data) {
  i2s_event_t event;
  bool more = xQueueReceive(queue(), &event, 0);
  if (more) *data = event.type;
  return more;
}

MODULE_IMPLEMENTATION(i2s, MODULE_I2S);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  I2SResourceGroup* i2s = _new I2SResourceGroup(process, EventQueueEventSource::instance());
  if (!i2s) {
    MALLOC_FAILED;
  }

  proxy->set_external_address(i2s);
  return proxy;
}


PRIMITIVE(create) {
  ARGS(I2SResourceGroup, group, int, sck_pin, int, ws_pin, int, tx_pin,
       int, rx_pin, int, mclk_pin,
       uint32, sample_rate, int, bits_per_sample, int, buffer_size,
       bool, is_master, int, mclk_multiplier, bool, use_apll);

  int fixed_mclk = 0;
  if (mclk_pin != -1) {
    if (mclk_multiplier != 128 && mclk_multiplier != 256 && mclk_multiplier != 384) INVALID_ARGUMENT;
    fixed_mclk = mclk_multiplier * sample_rate;
  }

  if (bits_per_sample != 16 && bits_per_sample != 24 && bits_per_sample != 32) INVALID_ARGUMENT;

  i2s_port_t port = i2s_ports.any();
  if (port == kInvalidPort) OUT_OF_RANGE;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    i2s_ports.put(port);
    ALLOCATION_FAILED;
  }

  int mode;
  if (is_master) {
    mode = I2S_MODE_MASTER;
  } else {
    mode = I2S_MODE_SLAVE;
  }

  if (tx_pin != -1) {
    mode |= I2S_MODE_TX;
  }

  if (rx_pin != -1) {
    mode |= I2S_MODE_RX;
  }

  i2s_config_t config = {
    .mode = static_cast<i2s_mode_t>(mode),
    .sample_rate = sample_rate,
    .bits_per_sample = static_cast<i2s_bits_per_sample_t>(bits_per_sample),
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = 0, // default interrupt priority
    // TODO(anders): Buffer count should be computed as a rate (buffer_size and sample rate).
    .dma_buf_count = 4,
    // TODO(anders): Divide buf_len (and grow buf-count) if buffer_size is > 1024.
    .dma_buf_len = buffer_size / (bits_per_sample / 8),
    .use_apll = use_apll,
    .fixed_mclk = fixed_mclk
  };

  struct {
    i2s_port_t port;
    i2s_config_t config;
    QueueHandle_t queue;
    esp_err_t err;
  } args {
    .port = port,
    .config = config
  };
  SystemEventSource::instance()->run([&]() -> void {
    args.err = i2s_driver_install(args.port, &args.config, 32, &args.queue);
  });
  if (args.err != ESP_OK) {
    i2s_ports.put(port);
    return Primitive::os_error(args.err, process);
  }

  i2s_pin_config_t pin_config = {
      .mck_io_num = mclk_pin >=0 ? mclk_pin: I2S_PIN_NO_CHANGE,
    .bck_io_num = sck_pin >= 0 ? sck_pin : I2S_PIN_NO_CHANGE,
    .ws_io_num = ws_pin >= 0 ? ws_pin : I2S_PIN_NO_CHANGE,
    .data_out_num = tx_pin >= 0 ? tx_pin : I2S_PIN_NO_CHANGE,
    .data_in_num = rx_pin >= 0 ? rx_pin : I2S_PIN_NO_CHANGE
  };
  esp_err_t err = i2s_set_pin(port, &pin_config);
  if (err != ESP_OK) {
    SystemEventSource::instance()->run([&]() -> void {
      i2s_driver_uninstall(port);
    });
    i2s_ports.put(port);
    return Primitive::os_error(err, process);
  }

  I2SResource* i2s = _new I2SResource(group, port, buffer_size, args.queue);
  if (!i2s) {
    SystemEventSource::instance()->run([&]() -> void {
      i2s_driver_uninstall(port);
    });
    i2s_ports.put(port);
    MALLOC_FAILED;
  }

  group->register_resource(i2s);
  proxy->set_external_address(i2s);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(I2SResourceGroup, group, I2SResource, i2s);
  group->unregister_resource(i2s);
  i2s_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(write) {
  ARGS(I2SResource, i2s, Blob, buffer);

  if (buffer.length() % i2s->alignment() != 0) INVALID_ARGUMENT;

  size_t written = 0;
  esp_err_t err = i2s_write(i2s->port(), buffer.address(), buffer.length(), &written, 0);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return Smi::from(written);
}

PRIMITIVE(read) {
  ARGS(I2SResource, i2s);

  Error* error = null;
  ByteArray* data = process->allocate_byte_array(i2s->alignment(), &error, /*force_external*/ true);
  if (data == null) return error;

  ByteArray::Bytes rx(data);
  size_t read = 0;
  esp_err_t err = i2s_read(i2s->port(), rx.address(), rx.length(), &read, 0);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  data->resize_external(process, read);
  return data;
}

PRIMITIVE(read_to_buffer) {
  ARGS(I2SResource, i2s, MutableBlob, buffer);

  if (buffer.length() % i2s->alignment() != 0) INVALID_ARGUMENT;

  size_t read = 0;
  esp_err_t err = i2s_read(i2s->port(), static_cast<void*>(buffer.address()), buffer.length(), &read, 0);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return Smi::from(read);
}

} // namespace toit

#endif // TOIT_FREERTOS

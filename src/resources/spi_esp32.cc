// Copyright (C) 2018 Toitware ApS.
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

#include <driver/gpio.h>
#include <driver/spi_master.h>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"

#include "spi_esp32.h"

namespace toit {

const spi_host_device_t kInvalidHostDevice = spi_host_device_t(-1);

static ResourcePool<spi_host_device_t, kInvalidHostDevice> spi_host_devices(
  // SPI1_HOST is typically reserved for flash and spiram.
  SPI2_HOST
#if SOC_SPI_PERIPH_NUM > 2
  , SPI3_HOST
#endif
);

SpiResourceGroup::SpiResourceGroup(Process* process, EventSource* event_source, spi_host_device_t host_device)
    : ResourceGroup(process, event_source)
    , host_device_(host_device) {}

SpiResourceGroup::~SpiResourceGroup() {
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(spi_bus_free(host_device_));
  });
  spi_host_devices.put(host_device_);
}

MODULE_IMPLEMENTATION(spi, MODULE_SPI);

PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  spi_host_device_t host_device = kInvalidHostDevice;

  // Check if there is a preferred device.
  // TODO(florian): match against the preferred pins for each device.
  if ((mosi == -1 || mosi == 13) &&
      (miso == -1 || miso == 12) &&
      (clock == -1 || clock == 14)) {
    host_device = SPI2_HOST;
  }
#if SOC_SPI_PERIPH_NUM > 2
  if ((mosi == -1 || mosi == 23) &&
      (miso == -1 || miso == 19) &&
      (clock == -1 || clock == 18)) {
    host_device = SPI3_HOST;
  }
#endif
  host_device = spi_host_devices.preferred(host_device);
  if (host_device == kInvalidHostDevice) FAIL(ALREADY_IN_USE);

  spi_bus_config_t conf = {};
  conf.mosi_io_num = mosi;
  conf.miso_io_num = miso;
  conf.sclk_io_num = clock;
  conf.quadwp_io_num = -1;
  conf.quadhd_io_num = -1;
  conf.max_transfer_sz = 0;
  conf.flags = 0;
  conf.intr_flags = ESP_INTR_FLAG_IRAM;
  CAPTURE2(spi_host_device_t, host_device, spi_bus_config_t, conf);
  esp_err_t err = ESP_OK;
  SystemEventSource::instance()->run([&]() -> void {
    err = spi_bus_initialize(capture.host_device, &capture.conf, SPI_DMA_CH_AUTO);
  });
  if (err != ESP_OK) {
    spi_host_devices.put(host_device);
    return Primitive::os_error(err, process);
  }

  SpiResourceGroup* spi = _new SpiResourceGroup(process, null, host_device);
  if (!spi) {
    spi_host_devices.put(host_device);
    FAIL(MALLOC_FAILED);
  }
  proxy->set_external_address(spi);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(SpiResourceGroup, spi);
  spi->tear_down();
  spi_proxy->clear_external_address();
  return process->null_object();
}

IRAM_ATTR static void spi_pre_transfer_callback(spi_transaction_t* t) {
  if (t->user != 0) {
    int dc = (int)t->user >> 8;
    int value = (int)t->user & 1;
    gpio_set_level((gpio_num_t)dc, value);
  }
}

PRIMITIVE(device) {
  ARGS(SpiResourceGroup, spi, int, cs, int, dc, int, command_bits, int, address_bits, int, frequency, int, mode);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  spi_device_interface_config_t conf = {
    .command_bits     = uint8(command_bits),
    .address_bits     = uint8(address_bits),
    .dummy_bits       = 0,
    .mode             = uint8(mode),
    .clock_source     = SPI_CLK_SRC_DEFAULT,
    .duty_cycle_pos   = 0,
    .cs_ena_pretrans  = 0,
    .cs_ena_posttrans = 0,
    .clock_speed_hz   = frequency,
    .input_delay_ns   = 0,
    .spics_io_num     = cs,
    .flags            = 0,
    .queue_size       = 1,
    .pre_cb           = null,
    .post_cb          = null,
  };
  if (dc != -1) {
    conf.pre_cb = spi_pre_transfer_callback;
  }

  spi_device_handle_t device;
  esp_err_t err = spi_bus_add_device(spi->host_device(), &conf, &device);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  SpiDevice* spi_device = _new SpiDevice(spi, device, dc);
  if (spi_device == null) {
    spi_bus_remove_device(device);
    FAIL(MALLOC_FAILED);
  }

  spi->register_resource(spi_device);
  proxy->set_external_address(spi_device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(SpiResourceGroup, spi, SpiDevice, device);
  spi->unregister_resource(device);
  return process->null_object();
}

PRIMITIVE(transfer) {
  ARGS(SpiDevice, device, MutableBlob, tx, int, command, int64, address, int, from, int, to, bool, read, int, dc, bool, keep_cs_active);

  if (from < 0 || from > to || to > tx.length()) FAIL(OUT_OF_BOUNDS);

  size_t length = to - from;

  uint32_t flags = 0;
  if (keep_cs_active) flags |= SPI_TRANS_CS_KEEP_ACTIVE;

  spi_transaction_t trans = {
    .flags = flags,
    .cmd = uint16(command),
    .addr = uint64(address),
    .length = length * 8,
    .rxlength = 0,
    .user = null,
    .tx_buffer = tx.address() + from,
    .rx_buffer = null,
  };

  bool using_buffer = false;
  if (read) {
    if (length <= SpiDevice::BUFFER_SIZE) {
      trans.rx_buffer = device->buffer();
      using_buffer = true;
    } else {
      // Reuse buffer (no need for memcpy, but is slightly slower).
      trans.rx_buffer = tx.address() + from;
    }
  }

  if (device->dc() != -1) {
    trans.user = (void*)((device->dc() << 8) | dc);
  }

  esp_err_t err = spi_device_polling_transmit(device->handle(), &trans);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  if (using_buffer) {
    memcpy(tx.address() + from, trans.rx_buffer, length);
  }

  return process->null_object();
}

PRIMITIVE(acquire_bus) {
  ARGS(SpiDevice, device);
  esp_err_t err = spi_device_acquire_bus(device->handle(), portMAX_DELAY);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  return process->null_object();
}

PRIMITIVE(release_bus) {
  ARGS(SpiDevice, device);
  spi_device_release_bus(device->handle());
  return process->null_object();
}

} // namespace toit

#endif // TOIT_ESP32

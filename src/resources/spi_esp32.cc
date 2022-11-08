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

#ifdef TOIT_FREERTOS

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

ResourcePool<int, 0> dma_channels(1, 2);

const spi_host_device_t kInvalidHostDevice = spi_host_device_t(-1);

ResourcePool<spi_host_device_t, kInvalidHostDevice> spi_host_devices(
#ifdef CONFIG_IDF_TARGET_ESP32S3
  SPI2_HOST,
  SPI3_HOST
#elif CONFIG_IDF_TARGET_ESP32S2
  SPI2_HOST,
  SPI3_HOST
#elif CONFIG_IDF_TARGET_ESP32C3
  SPI3_HOST
#else
  HSPI_HOST,
  VSPI_HOST
#endif
);

SPIResourceGroup::SPIResourceGroup(Process* process, EventSource* event_source, spi_host_device_t host_device,
                                   int dma_chan)
    : ResourceGroup(process, event_source)
    , host_device_(host_device)
    , dma_chan_(dma_chan) {}

SPIResourceGroup::~SPIResourceGroup() {
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(spi_bus_free(host_device_));
  });
  spi_host_devices.put(host_device_);
  dma_channels.put(dma_chan_);
}

MODULE_IMPLEMENTATION(spi, MODULE_SPI);

PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);

  spi_host_device_t host_device = kInvalidHostDevice;

  // Check if there is a preferred device.
  if ((mosi == -1 || mosi == 13) &&
      (miso == -1 || miso == 12) &&
      (clock == -1 || clock == 14)) {
#ifdef CONFIG_IDF_TARGET_ESP32C3
    host_device = SPI3_HOST;
#elif CONFIG_IDF_TARGET_ESP32S3
    host_device = SPI2_HOST;
#else
    host_device = HSPI_HOST;
#endif
  }
  if ((mosi == -1 || mosi == 23) &&
      (miso == -1 || miso == 19) &&
      (clock == -1 || clock == 18)) {
#ifdef CONFIG_IDF_TARGET_ESP32C3
    host_device = SPI3_HOST;
#elif CONFIG_IDF_TARGET_ESP32S3
    host_device = SPI3_HOST;
#elif CONFIG_IDF_TARGET_ESP32S2
    host_device = SPI3_HOST;
#else
    host_device = VSPI_HOST;
#endif
  }
  host_device = spi_host_devices.preferred(host_device);
  if (host_device == kInvalidHostDevice) OUT_OF_RANGE;

  int dma_chan = dma_channels.any();
  if (dma_chan == 0) {
    spi_host_devices.put(host_device);
    ALLOCATION_FAILED;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    spi_host_devices.put(host_device);
    dma_channels.put(dma_chan);
    ALLOCATION_FAILED;
  }

  spi_bus_config_t conf = {};
  conf.mosi_io_num = mosi;
  conf.miso_io_num = miso;
  conf.sclk_io_num = clock;
  conf.quadwp_io_num = -1;
  conf.quadhd_io_num = -1;
  conf.max_transfer_sz = 0;
  conf.flags = 0;
  conf.intr_flags = ESP_INTR_FLAG_IRAM;
  struct {
    spi_host_device_t host_device;
    int dma_chan;
    esp_err_t err;
  } args {
    .host_device = host_device,
#ifdef CONFIG_IDF_TARGET_ESP32S3
    .dma_chan = SPI_DMA_CH_AUTO,
#else
    .dma_chan = dma_chan,
#endif
    .err = ESP_OK,
  };
  SystemEventSource::instance()->run([&]() -> void {
    args.err = spi_bus_initialize(args.host_device, &conf, args.dma_chan);
  });
  if (args.err != ESP_OK) {
    spi_host_devices.put(host_device);
    dma_channels.put(dma_chan);
    return Primitive::os_error(args.err, process);
  }

  // TODO: Reclaim dma channel.
  SPIResourceGroup* spi = _new SPIResourceGroup(process, null, host_device, dma_chan);
  if (!spi) {
    spi_host_devices.put(host_device);
    dma_channels.put(dma_chan);
    MALLOC_FAILED;
  }
  proxy->set_external_address(spi);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(SPIResourceGroup, spi);
  spi->tear_down();
  spi_proxy->clear_external_address();
  return process->program()->null_object();
}

IRAM_ATTR static void spi_pre_transfer_callback(spi_transaction_t* t) {
  if (t->user != 0) {
    int dc = (int)t->user >> 8;
    int value = (int)t->user & 1;
    gpio_set_level((gpio_num_t)dc, value);
  }
}

PRIMITIVE(device) {
  ARGS(SPIResourceGroup, spi, int, cs, int, dc, int, command_bits, int, address_bits, int, frequency, int, mode);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  spi_device_interface_config_t conf = {
    .command_bits     = uint8(command_bits),
    .address_bits     = uint8(address_bits),
    .dummy_bits       = 0,
    .mode             = uint8(mode),
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

  SPIDevice* spi_device = _new SPIDevice(spi, device, dc);
  if (spi_device == null) {
    spi_bus_remove_device(device);
    MALLOC_FAILED;
  }

  spi->register_resource(spi_device);
  proxy->set_external_address(spi_device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(SPIResourceGroup, spi, SPIDevice, device);
  spi->unregister_resource(device);
  return process->program()->null_object();
}

PRIMITIVE(transfer) {
  ARGS(SPIDevice, device, MutableBlob, tx, int, command, int64, address, int, from, int, to, bool, read, int, dc, bool, keep_cs_active);

  if (from < 0 || from > to || to > tx.length()) OUT_OF_BOUNDS;

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
    if (length <= SPIDevice::BUFFER_SIZE) {
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

  return process->program()->null_object();
}

PRIMITIVE(acquire_bus) {
  ARGS(SPIDevice, device);
  esp_err_t err = spi_device_acquire_bus(device->handle(), portMAX_DELAY);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  return process->program()->null_object();
}

PRIMITIVE(release_bus) {
  ARGS(SPIDevice, device);
  spi_device_release_bus(device->handle());
  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS

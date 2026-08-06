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
#include <driver/spi_slave.h>
#include <esp_heap_caps.h>
#if SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE
#include <esp_private/esp_cache_private.h>
#endif

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"
#include "../event_sources/ev_queue_esp32.h"

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
  // Release any GPIO pins this bus reserved (mosi/miso/clock).
  owned_pins_.release();
}

SpiTargetResource::~SpiTargetResource() {
  // Uninstall the driver before releasing buffers that may still be referenced
  // by a queued transaction. This also makes process teardown safe when Toit
  // code abandoned a PendingExchange that ESP-IDF cannot cancel explicitly.
  if (initialized_) FATAL_IF_NOT_ESP_OK(spi_slave_free(host_device_));
  if (operation_in_flight_) finish_operation();
  vQueueDeleteWithCaps(queue());
  spi_host_devices.put(host_device_);
  owned_pins_.release();
}

void SpiTargetResource::prepare_operation(uint8_t* tx_buffer,
                                          uint8_t* rx_buffer,
                                          size_t receive_size,
                                          size_t transfer_size) {
  ASSERT(!operation_in_flight_);
  tx_buffer_ = tx_buffer;
  rx_buffer_ = rx_buffer;
  receive_size_ = receive_size;
  transaction_ = {
    .flags = 0,
    .length = transfer_size * 8,
    .trans_len = 0,
    .tx_buffer = tx_buffer,
    .rx_buffer = rx_buffer,
    .user = this,
  };
  operation_in_flight_ = true;
}

void SpiTargetResource::finish_operation() {
  ASSERT(operation_in_flight_);
  free(tx_buffer_);
  free(rx_buffer_);
  tx_buffer_ = null;
  rx_buffer_ = null;
  receive_size_ = 0;
  transaction_ = {};
  operation_in_flight_ = false;
}

MODULE_IMPLEMENTATION(spi, MODULE_SPI);

PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // Decode the pins and reserve them from the shared
  // pool. The reserver releases everything again if we leave without `keep()`.
  GpioPinReserver reserver;
  bool reserve_ok = true;
  int mosi_num = reserver.decode_and_take(mosi, &reserve_ok);
  int miso_num = reserver.decode_and_take(miso, &reserve_ok);
  int clock_num = reserver.decode_and_take(clock, &reserve_ok);
  if (!reserve_ok) FAIL(ALREADY_IN_USE);

  spi_host_device_t host_device = kInvalidHostDevice;

  // Check if there is a preferred device.
  // TODO(florian): match against the preferred pins for each device.
  if ((mosi_num == -1 || mosi_num == 13) &&
      (miso_num == -1 || miso_num == 12) &&
      (clock_num == -1 || clock_num == 14)) {
    host_device = SPI2_HOST;
  }
#if SOC_SPI_PERIPH_NUM > 2
  if ((mosi_num == -1 || mosi_num == 23) &&
      (miso_num == -1 || miso_num == 19) &&
      (clock_num == -1 || clock_num == 18)) {
    host_device = SPI3_HOST;
  }
#endif
  host_device = spi_host_devices.preferred(host_device);
  if (host_device == kInvalidHostDevice) FAIL(ALREADY_IN_USE);

  spi_bus_config_t conf = {};
  conf.mosi_io_num = mosi_num;
  conf.miso_io_num = miso_num;
  conf.sclk_io_num = clock_num;
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

  // The reservation now belongs to the resource and is released on close.
  spi->owned_pins().adopt(reserver);
  reserver.keep();

  proxy->set_external_address(spi);

  return proxy;
}

PRIMITIVE(target_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new SpiTargetResourceGroup(
      process, EventQueueEventSource::instance());
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

IRAM_ATTR static void spi_target_done_callback(spi_slave_transaction_t* transaction) {
  auto resource = static_cast<SpiTargetResource*>(transaction->user);
  resource->complete_from_isr();
}

IRAM_ATTR static void spi_target_ready_callback(spi_slave_transaction_t* transaction) {
  auto resource = static_cast<SpiTargetResource*>(transaction->user);
  resource->ready_from_isr();
}

PRIMITIVE(target_create) {
  ARGS(SpiTargetResourceGroup, group,
       int, mosi,
       int, miso,
       int, clock,
       int, cs,
       int, mode,
       bool, transmit_lsb_first,
       bool, receive_lsb_first,
       uint32, max_transfer_size,
       bool, dma);

  if (mode < 0 || mode > 3 || max_transfer_size == 0) FAIL(INVALID_ARGUMENT);
  if (!dma && max_transfer_size > SOC_SPI_MAXIMUM_BUFFER_SIZE) FAIL(INVALID_ARGUMENT);

  size_t buffer_alignment = 4;
#if SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE
  if (dma) {
    esp_err_t err = esp_cache_get_alignment(MALLOC_CAP_DMA, &buffer_alignment);
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
#endif
  ASSERT(Utils::is_power_of_two(buffer_alignment));
  size_t driver_max_transfer_size =
      (static_cast<size_t>(max_transfer_size) + buffer_alignment - 1) &
      ~(buffer_alignment - 1);
  if (driver_max_transfer_size < max_transfer_size ||
      driver_max_transfer_size > INT_MAX) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  GpioPinReserver reserver;
  bool reserve_ok = true;
  int mosi_num = reserver.decode_and_take(mosi, &reserve_ok);
  int miso_num = reserver.decode_and_take(miso, &reserve_ok);
  int clock_num = reserver.decode_and_take(clock, &reserve_ok);
  int cs_num = reserver.decode_and_take(cs, &reserve_ok);
  if (!reserve_ok) FAIL(ALREADY_IN_USE);
  if (clock_num < 0 || cs_num < 0) FAIL(INVALID_ARGUMENT);
  if (mosi_num < 0 && miso_num < 0) FAIL(INVALID_ARGUMENT);
#if CONFIG_IDF_TARGET_ESP32
  if (dma && mosi_num >= 0 && (miso_num >= 0 || (mode & 1) != 0)) {
    FAIL(INVALID_ARGUMENT);
  }
#endif

  spi_host_device_t host_device = spi_host_devices.preferred(kInvalidHostDevice);
  if (host_device == kInvalidHostDevice) FAIL(ALREADY_IN_USE);
  bool host_owned = true;
  Defer release_host { [&] {
    if (host_owned) spi_host_devices.put(host_device);
  } };

  QueueHandle_t event_queue = xQueueCreateWithCaps(
      1, sizeof(word), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (event_queue == null) FAIL(MALLOC_FAILED);

  auto resource = _new SpiTargetResource(
      group, host_device, event_queue, max_transfer_size, buffer_alignment, dma);
  if (resource == null) {
    vQueueDeleteWithCaps(event_queue);
    FAIL(MALLOC_FAILED);
  }
  host_owned = false;
  bool registered = false;
  Defer delete_resource { [&] { if (!registered) delete resource; } };

  spi_bus_config_t bus_config = {};
  bus_config.mosi_io_num = mosi_num;
  bus_config.miso_io_num = miso_num;
  bus_config.sclk_io_num = clock_num;
  bus_config.quadwp_io_num = -1;
  bus_config.quadhd_io_num = -1;
  bus_config.max_transfer_sz = driver_max_transfer_size;
  bus_config.flags = 0;
  bus_config.intr_flags = ESP_INTR_FLAG_IRAM;

  uint32_t flags = SPI_SLAVE_NO_RETURN_RESULT;
  if (transmit_lsb_first) flags |= SPI_SLAVE_TXBIT_LSBFIRST;
  if (receive_lsb_first) flags |= SPI_SLAVE_RXBIT_LSBFIRST;
  spi_slave_interface_config_t target_config = {
    .spics_io_num = cs_num,
    .flags = flags,
    .queue_size = 1,
    .mode = static_cast<uint8_t>(mode),
    .post_setup_cb = spi_target_ready_callback,
    .post_trans_cb = spi_target_done_callback,
  };

  esp_err_t err = spi_slave_initialize(
      host_device,
      &bus_config,
      &target_config,
      dma ? SPI_DMA_CH_AUTO : SPI_DMA_DISABLED);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  resource->set_initialized();

  resource->owned_pins().adopt(reserver);
  reserver.keep();
  group->register_resource(resource);
  proxy->set_external_address(resource);
  registered = true;
  return proxy;
}

PRIMITIVE(target_close) {
  ARGS(SpiTargetResourceGroup, group, SpiTargetResource, resource);
  if (resource->operation_in_flight()) FAIL(INVALID_STATE);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

static uint8_t* allocate_dma_buffer(size_t size, size_t alignment) {
  if (size == 0) return null;
  size_t allocation_size = (size + alignment - 1) & ~(alignment - 1);
  if (allocation_size < size) return null;
  return static_cast<uint8_t*>(heap_caps_aligned_alloc(
      alignment,
      allocation_size,
      MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT));
}

PRIMITIVE(target_transfer_start) {
  ARGS(SpiTargetResource, resource,
       Blob, transmit,
       uint32, receive_size,
       uint8, fill_byte);
  if (resource->operation_in_flight()) FAIL(INVALID_STATE);

  size_t transmit_size = transmit.length();
  size_t transfer_size = Utils::max(transmit_size, static_cast<size_t>(receive_size));
  if (transfer_size == 0 || transfer_size > resource->max_transfer_size()) {
    FAIL(INVALID_ARGUMENT);
  }
  size_t alignment = resource->buffer_alignment();
  size_t driver_transfer_size =
      (transfer_size + alignment - 1) & ~(alignment - 1);
  ASSERT(driver_transfer_size >= transfer_size);

  uint8_t* tx_buffer = allocate_dma_buffer(driver_transfer_size, alignment);
  if (tx_buffer == null) return Primitive::os_error(ESP_ERR_NO_MEM, process);
  bool buffers_handed_to_resource = false;
  Defer free_buffers { [&] {
    if (!buffers_handed_to_resource) free(tx_buffer);
  } };
  memset(tx_buffer, fill_byte, driver_transfer_size);
  memcpy(tx_buffer, transmit.address(), transmit_size);

  // The driver programs one length for both directions. Even when the caller
  // only wants a prefix of the received data, DMA may write the full transfer.
  uint8_t* rx_buffer = allocate_dma_buffer(
      receive_size == 0 ? 0 : driver_transfer_size, alignment);
  if (receive_size != 0 && rx_buffer == null) {
    return Primitive::os_error(ESP_ERR_NO_MEM, process);
  }
  Defer free_receive_buffer { [&] {
    if (!buffers_handed_to_resource) free(rx_buffer);
  } };

  resource->prepare_operation(
      tx_buffer, rx_buffer, receive_size, driver_transfer_size);
  buffers_handed_to_resource = true;
  bool dispatched = false;
  Defer cancel_operation { [&] {
    if (!dispatched) resource->finish_operation();
  } };

  esp_err_t err = spi_slave_queue_trans(
      resource->host_device(), resource->transaction(), 0);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  dispatched = true;
  return process->null_object();
}

PRIMITIVE(target_transfer_finish) {
  ARGS(SpiTargetResource, resource, MutableBlob, receive_buffer);
  if (!resource->operation_in_flight()) FAIL(INVALID_STATE);
  if (receive_buffer.length() < resource->receive_size()) FAIL(OUT_OF_BOUNDS);

  size_t transferred_bytes = (resource->transferred_bits() + 7) / 8;
  size_t result_size = Utils::min(transferred_bytes, resource->receive_size());
#if CONFIG_IDF_TARGET_ESP32
  // Classic ESP32 target DMA only commits complete words to its receive
  // buffer. ESP-IDF documents that a controller's trailing bytes are
  // discarded when its transaction length is not a multiple of four.
  if (resource->dma()) result_size &= ~static_cast<size_t>(3);
#endif
  if (result_size != 0) {
    memcpy(receive_buffer.address(), resource->receive_buffer(), result_size);
  }
  resource->finish_operation();
  return Smi::from(result_size);
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
  ARGS(SpiResourceGroup, spi,
       int, cs,
       int, dc,
       int, command_bits,
       int, address_bits,
       int, frequency,
       int, mode,
       int, cs_setup_cycles,
       int, cs_hold_cycles);

  if (cs_setup_cycles < 0 || cs_setup_cycles > 16 ||
      cs_hold_cycles < 0 || cs_hold_cycles > 16) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // Decode the pins and reserve them from the shared
  // pool. The reserver releases everything again if we leave without `keep()`.
  GpioPinReserver reserver;
  bool reserve_ok = true;
  int cs_num = reserver.decode_and_take(cs, &reserve_ok);
  bool dc_owned = false;
  int dc_num = reserver.decode_and_take(dc, &reserve_ok, &dc_owned);
  if (!reserve_ok) FAIL(ALREADY_IN_USE);

  // The dc pin is toggled in software, so it must be an output. We configure it
  // here when we reserved it. A deprecated gpio.Pin (old API) is configured on
  // the Toit side instead.
  if (dc_owned) {
    gpio_config_t dc_cfg = {
      .pin_bit_mask = 1ULL << dc_num,
      .mode = GPIO_MODE_OUTPUT,
      .pull_up_en = GPIO_PULLUP_DISABLE,
      .pull_down_en = GPIO_PULLDOWN_DISABLE,
      .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t cfg_err = gpio_config(&dc_cfg);
    if (cfg_err != ESP_OK) return Primitive::os_error(cfg_err, process);
  }

  spi_device_interface_config_t conf = {
    .command_bits     = uint8(command_bits),
    .address_bits     = uint8(address_bits),
    .dummy_bits       = 0,
    .mode             = uint8(mode),
    .clock_source     = SPI_CLK_SRC_DEFAULT,
    .duty_cycle_pos   = 0,
    .cs_ena_pretrans  = static_cast<uint16_t>(cs_setup_cycles),
    .cs_ena_posttrans = static_cast<uint8_t>(cs_hold_cycles),
    .clock_speed_hz   = frequency,
    .input_delay_ns   = 0,
    .sample_point     = SPI_SAMPLING_POINT_PHASE_0,
    .spics_io_num     = cs_num,
    .flags            = 0,
    .queue_size       = 1,
    .pre_cb           = null,
    .post_cb          = null,
  };
  if (dc_num != -1) {
    conf.pre_cb = spi_pre_transfer_callback;
  }

  spi_device_handle_t device;
  esp_err_t err = spi_bus_add_device(spi->host_device(), &conf, &device);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  SpiDevice* spi_device = _new SpiDevice(spi, device, dc_num);
  if (spi_device == null) {
    spi_bus_remove_device(device);
    FAIL(MALLOC_FAILED);
  }

  // The reservation now belongs to the resource and is released on close.
  spi_device->owned_pins().adopt(reserver);
  reserver.keep();

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

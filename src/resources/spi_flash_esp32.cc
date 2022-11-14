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

#include "../resource.h"
#include "../objects_inline.h"
#include "../vm.h"
#include "spi_esp32.h"

#include "driver/sdspi_host.h"
#include "driver/spi_master.h"
#include <esp_vfs_fat.h>
#include <esp_flash_spi_init.h>

namespace toit {

class SPIFlashResourceGroup: public ResourceGroup {
 public:
  TAG(SPIFlashResourceGroup);
  SPIFlashResourceGroup(Process* process, const char* mount_point)
     : ResourceGroup(process, null)
     , mount_point_(mount_point) {
  }

  ~SPIFlashResourceGroup() override {
    // SD-card.
    if (card_) esp_vfs_fat_sdcard_unmount(mount_point_, card_);

    // NOR flash.
    if (wl_handle_ != -1) esp_vfs_fat_spiflash_unmount(mount_point_, wl_handle_);
    if (data_partition_) esp_partition_deregister_external(data_partition_);
    if (chip_) spi_bus_remove_flash_device(chip_);

#ifdef CONFIG_SPI_FLASH_NAND_ENABLED
    // NAND flash.
    if (nand_flash_device_) esp_vfs_fat_nand_unmount(mount_point_, nand_flash_device_);
    if (nand_flash_device_) spi_nand_flash_deinit_device(nand_flash_device_);
    if (nand_spi_device_) spi_bus_remove_device(nand_spi_device_);
#endif
    free(void_cast(const_cast<char*>(mount_point_)));
  }

  esp_flash_t* chip() { return chip_; }
  void set_data_partition(const esp_partition_t* data_partition) { data_partition_ = data_partition; }
  void set_wl_handle(wl_handle_t handle) { wl_handle_ = handle; }
#ifdef CONFIG_SPI_FLASH_NAND_ENABLED
  void set_nand_flash_device(spi_nand_flash_device_t* nand_flash_device) { nand_flash_device_ = nand_flash_device; }
  void set_nand_spi_device(spi_device_handle_t nand_spi_device) { nand_spi_device_ = nand_spi_device; }
#endif
  void set_card(sdmmc_card_t* card) { card_ = card; }
  void set_chip(esp_flash_t* chip) { chip_ = chip; }

 private:
  const char* mount_point_;
  sdmmc_card_t* card_ = null;
  esp_flash_t* chip_ = null;
  const esp_partition_t* data_partition_ = null;
  wl_handle_t wl_handle_ = -1;
#ifdef CONFIG_SPI_FLASH_NAND_ENABLED
  spi_nand_flash_device_t* nand_flash_device_ = null;
  spi_device_handle_t nand_spi_device_ = null;
#endif
};

MODULE_IMPLEMENTATION(spi_flash, MODULE_SPI_FLASH);

static HeapObject* init_common(Process* process, const char* mount_point,
                               SPIFlashResourceGroup** group, char** mount_point_buffer_output) {
  char* mount_point_buffer = static_cast<char*>(malloc(strlen(mount_point)));
  if (!*mount_point_buffer) MALLOC_FAILED;
  strcpy(mount_point_buffer, mount_point);

  *group = _new SPIFlashResourceGroup(process, mount_point_buffer);

  if (!group) {
    free(mount_point_buffer);
    ALLOCATION_FAILED;
  }

  if (mount_point_buffer_output) *mount_point_buffer_output = mount_point_buffer;
  return null;
}

PRIMITIVE(init_sdcard) {
  ARGS(cstring, mount_point, SPIResourceGroup, spi_host, int, gpio_cs, int, format_if_mount_failed, int, max_files, int, allocation_unit_size)
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  SPIFlashResourceGroup* group;
  auto init_result = init_common(process, mount_point, &group, null);
  if (init_result != null) return init_result;

  sdmmc_host_t host = SDSPI_HOST_DEFAULT();
  host.slot = spi_host->host_device();

  sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
  slot_config.host_id = static_cast<spi_host_device_t>(host.slot);
  slot_config.gpio_cs = static_cast<gpio_num_t>(gpio_cs);

  esp_vfs_fat_sdmmc_mount_config_t mount_config = {
      .format_if_mount_failed = static_cast<bool>(format_if_mount_failed),
      .max_files = max_files,
      .allocation_unit_size = static_cast<size_t>(allocation_unit_size)
  };
  sdmmc_card_t* card;
  esp_err_t ret = esp_vfs_fat_sdspi_mount(mount_point, &host, &slot_config, &mount_config, &card);
  if (ret != ESP_OK) {
    return Primitive::os_error(ret, process);
  }

  group->set_card(card);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(init_nor_flash) {
  ARGS(cstring, mount_point, SPIResourceGroup, spi_bus, int, gpio_cs,int, frequency, int, format_if_mount_failed, int, max_files, int, allocation_unit_size)

  if (frequency < 0 || frequency > ESP_FLASH_80MHZ) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  char* mount_point_buffer;
  SPIFlashResourceGroup* group;
  auto init_result = init_common(process, mount_point, &group, &mount_point_buffer);
  if (init_result != null) return init_result;

  esp_flash_spi_device_config_t conf = {
      .host_id = spi_bus->host_device(),
      .cs_io_num = gpio_cs,
      .io_mode = SPI_FLASH_FASTRD,
      .speed = static_cast<esp_flash_speed_t>(frequency),
      .input_delay_ns = 0,
      .cs_id = 0
  };

  esp_flash_t* chip;
  esp_err_t ret = spi_bus_add_flash_device(&chip, &conf);
  if (ret != ESP_OK) {
    return Primitive::os_error(ret, process);
  }

  group->set_chip(chip);

  ret = esp_flash_init(chip);

  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }

  size_t size;
  ret = esp_flash_get_size(chip, &size);
  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }

  // We are using mount_point as the label for the external partition since that should
  // be unique when multiple NOR flash chips are used.
  const esp_partition_t* partition;
  ret = esp_partition_register_external(chip, 0, size, mount_point,
                                        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_FAT, &partition);
  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }

  group->set_data_partition(partition);

  esp_vfs_fat_mount_config_t mount_config = {
      .format_if_mount_failed = static_cast<bool>(format_if_mount_failed),
      .max_files = max_files,
      .allocation_unit_size = static_cast<size_t>(allocation_unit_size)
  };

  wl_handle_t wl_handle;
  ret = esp_vfs_fat_spiflash_mount(mount_point_buffer, mount_point, &mount_config, &wl_handle);
  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }

  group->set_wl_handle(wl_handle);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(init_nand_flash) {
#ifdef CONFIG_SPI_FLASH_NAND_ENABLED
  ARGS(cstring, mount_point, SPIResourceGroup, spi_bus, int, gpio_cs, int, frequency, int, format_if_mount_failed, int, max_files, int, allocation_unit_size);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  SPIFlashResourceGroup* group;
  auto init_result = init_common(process, mount_point, &group, null);
  if (init_result != null) return init_result;

  spi_device_interface_config_t dev_cfg = {
      .mode = 0,
      .clock_speed_hz = frequency,
      .spics_io_num = gpio_cs,
      .flags = SPI_DEVICE_HALFDUPLEX,
      .queue_size = 1
  };
  spi_device_handle_t nand_spi_device;
  esp_err_t ret = spi_bus_add_device(SPI3_HOST, &dev_cfg, &nand_spi_device);
  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }
  group->set_nand_spi_device(nand_spi_device);

  spi_nand_flash_config_t nand_config = {
      .device_handle = nand_spi_device,
      .gc_factor = 45
  };
  spi_nand_flash_device_t* nand_flash_device;
  ret = spi_nand_flash_init_device(&nand_config, &nand_flash_device);
  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }
  group->set_nand_flash_device(nand_flash_device);

  esp_vfs_fat_mount_config_t mount_config = {
      .format_if_mount_failed = static_cast<bool>(format_if_mount_failed),
      .max_files = max_files,
      .allocation_unit_size = static_cast<size_t>(allocation_unit_size)
  };

  ret = esp_vfs_fat_nand_mount(mp, nand_flash_device, &mount_config);
  if (ret != ESP_OK) {
    group->tear_down();
    return Primitive::os_error(ret, process);
  }

  proxy->set_external_address(group);
  return proxy;
#else
  UNIMPLEMENTED_PRIMITIVE;
#endif // CONFIG_SPI_FLASH_NAND_ENABLED

}

PRIMITIVE(close) {
  ARGS(SPIFlashResourceGroup, group)
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

}
#endif

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

#if defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_ETHERNET)

#include <esp_eth.h>
#include <esp_mac.h>
#include <esp_netif.h>
#include <rom/ets_sys.h>

#include "../resource.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../primitive.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"
#include "spi_esp32.h"

namespace toit {

enum {
  ETHERNET_CONNECTED    = 1 << 0,
  ETHERNET_DHCP_SUCCESS = 1 << 1,
  ETHERNET_DISCONNECTED = 1 << 2,
};

enum {
  MAC_CHIP_ESP32    = 0,
  MAC_CHIP_W5500    = 1,
  MAC_CHIP_OPENETH  = 2,
};

enum {
  PHY_CHIP_IP101    = 1,
  PHY_CHIP_LAN8720  = 2,
  PHY_CHIP_DP83848  = 3,
};

const int kInvalidEthernet = -1;

// Only allow one instance of WiFi running.
static ResourcePool<int, kInvalidEthernet> ethernet_pool(
    0
);

class EthernetResourceGroup : public ResourceGroup {
 public:
  TAG(EthernetResourceGroup);
  EthernetResourceGroup(Process* process, SystemEventSource* event_source, int id,
                        esp_eth_mac_t* mac, esp_eth_phy_t* phy,
                        esp_netif_t* netif, esp_eth_handle_t eth_handle,
                        esp_eth_netif_glue_handle_t netif_glue)
      : ResourceGroup(process, event_source)
      , id_(id)
      , mac_(mac)
      , phy_(phy)
      , netif_(netif)
      , eth_handle_(eth_handle)
      , netif_glue_(netif_glue) {}

  void connect() {
    ESP_ERROR_CHECK(esp_eth_start(eth_handle_));
  }

  ~EthernetResourceGroup() {
    ESP_ERROR_CHECK(esp_eth_stop(eth_handle_));
    ESP_ERROR_CHECK(esp_eth_del_netif_glue(netif_glue_));
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle_));
    esp_netif_destroy(netif_);
    ethernet_pool.put(id_);
    phy_->del(phy_);
    mac_->del(mac_);
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state);

  esp_err_t set_hostname(const char* hostname) {
    return esp_netif_set_hostname(netif_, hostname);
  }

 private:
  int id_;
  esp_eth_mac_t* mac_;
  esp_eth_phy_t* phy_;
  esp_netif_t* netif_;
  esp_eth_handle_t eth_handle_;
  esp_eth_netif_glue_handle_t netif_glue_;
 };

class EthernetEvents : public SystemResource {
 public:
  TAG(EthernetEvents);
  explicit EthernetEvents(EthernetResourceGroup* group)
      : SystemResource(group, ETH_EVENT) {}

  ~EthernetEvents() {}

 private:
  friend class EthernetResourceGroup;
};

class EthernetIpEvents : public SystemResource {
 public:
  TAG(EthernetIpEvents);
  explicit EthernetIpEvents(EthernetResourceGroup* group)
      : SystemResource(group, IP_EVENT, IP_EVENT_ETH_GOT_IP) {
    ip_address_ = 0;
  }

  uint32 ip_address() {
    return ip_address_;
  }

  void update_ip_address(uint32 addr) {
    ip_address_ = addr;
  }

 private:
  friend class EthernetResourceGroup;
  uint32 ip_address_;
};

uint32_t EthernetResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  SystemEvent* system_event = reinterpret_cast<SystemEvent*>(data);
  if (system_event->base == ETH_EVENT) {
    switch (system_event->id) {
      case ETHERNET_EVENT_CONNECTED:
        state |= ETHERNET_CONNECTED;
        break;

      case ETHERNET_EVENT_DISCONNECTED:
        break;

      case ETHERNET_EVENT_START:
        break;

      case ETHERNET_EVENT_STOP:
        break;

      default:
        ets_printf("unhandled Ethernet event: %d\n", system_event->id);
    }
  } else if (system_event->base == IP_EVENT) {
    switch (system_event->id) {
      case IP_EVENT_ETH_GOT_IP: {
        ip_event_got_ip_t* event = reinterpret_cast<ip_event_got_ip_t*>(system_event->event_data);
        static_cast<EthernetIpEvents*>(resource)->update_ip_address(event->ip_info.ip.addr);
        state |= ETHERNET_DHCP_SUCCESS;
        break;
      }

      default:
        ets_printf("unhandled Ethernet event: %d\n", system_event->id);
    }
  } else {
    FATAL("unhandled event: %d\n", system_event->base);
  }

  return state;
}

MODULE_IMPLEMENTATION(ethernet, MODULE_ETHERNET)

PRIMITIVE(init) {
  ARGS(int, mac_chip, int, phy_chip, int, phy_addr, int, phy_reset_num, int, mdc_num, int, mdio_num)

#if (!CONFIG_IDF_TARGET_ESP32)
  return Primitive::os_error(ESP_FAIL, process);
#else
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int id = ethernet_pool.any();
  if (id == kInvalidEthernet) FAIL(ALREADY_IN_USE);

  esp_netif_config_t cfg = ESP_NETIF_DEFAULT_ETH();
  esp_netif_t* netif = esp_netif_new(&cfg);
  if (!netif) {
    ethernet_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  // Init MAC and PHY configs to default.
  eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
  eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();

  phy_config.phy_addr = phy_addr;
  phy_config.reset_gpio_num = phy_reset_num;

  esp_eth_mac_t* mac;
  if (mac_chip == MAC_CHIP_ESP32) {
    eth_esp32_emac_config_t emac_config = ETH_ESP32_EMAC_DEFAULT_CONFIG();
    emac_config.smi_mdc_gpio_num = mdc_num;
    emac_config.smi_mdio_gpio_num = mdio_num;
    mac = esp_eth_mac_new_esp32(&emac_config, &mac_config);
#ifdef CONFIG_ETH_USE_OPENETH
  } else if (mac_chip == MAC_CHIP_OPENETH) {
    // Openeth is the network driver that is used with QEMU.
    mac = esp_eth_mac_new_openeth(&mac_config);
    phy_config.autonego_timeout_ms = 100;
#endif
  } else {
    FAIL(INVALID_ARGUMENT);
  }

  if (!mac) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    return Primitive::os_error(ESP_FAIL, process);
  }
  esp_eth_phy_t* phy = null;
  switch (phy_chip) {
    case PHY_CHIP_IP101:
      phy = esp_eth_phy_new_ip101(&phy_config);
      break;
    case PHY_CHIP_LAN8720:
      phy = esp_eth_phy_new_lan87xx(&phy_config);
      break;
    case PHY_CHIP_DP83848: {
      phy = esp_eth_phy_new_dp83848(&phy_config);
    }
  }
  if (!phy) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    mac->del(mac);
    return Primitive::os_error(ESP_ERR_INVALID_ARG, process);
  }

  esp_eth_config_t config = ETH_DEFAULT_CONFIG(mac, phy);
  esp_eth_handle_t eth_handle = NULL;
  esp_err_t err = esp_eth_driver_install(&config, &eth_handle);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    phy->del(phy);
    mac->del(mac);
    return Primitive::os_error(err, process);
  }

  esp_eth_netif_glue_handle_t netif_glue = esp_eth_new_netif_glue(eth_handle);
  // Attach Ethernet driver to TCP/IP stack.
  err = esp_netif_attach(netif, netif_glue);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    phy->del(phy);
    mac->del(mac);
    return Primitive::os_error(err, process);
  }

  EthernetResourceGroup* resource_group = _new EthernetResourceGroup(
    process, SystemEventSource::instance(), id, mac, phy, netif, eth_handle, netif_glue);
  if (!resource_group) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_del_netif_glue(netif_glue));
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    phy->del(phy);
    mac->del(mac);
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(resource_group);
  return proxy;
#endif
}


PRIMITIVE(init_spi) {
  ARGS(int, mac_chip, SpiResourceGroup, spi, int, frequency, int, cs, int, int_num)

#ifndef CONFIG_ETH_SPI_ETHERNET_W5500
  if (mac_chip == MAC_CHIP_W5500) {
    return Primitive::os_error(ESP_ERR_NOT_SUPPORTED, process);
  }
#endif
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int id = ethernet_pool.any();
  if (id == kInvalidEthernet) FAIL(ALREADY_IN_USE);

  esp_netif_config_t cfg = ESP_NETIF_DEFAULT_ETH();
  esp_netif_t* netif = esp_netif_new(&cfg);
  if (!netif) {
    ethernet_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  spi_host_device_t spi_host = spi->host_device();
  spi_device_interface_config_t spi_config = {
    .command_bits     = 0,
    .address_bits     = 0,
    .dummy_bits       = 0,
    .mode             = 0,
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

  // Init MAC and PHY configs to default.
  eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
  eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
  phy_config.reset_gpio_num = -1;

  esp_eth_mac_t* mac = null;
  esp_eth_phy_t* phy = null;
  switch (mac_chip) {
#ifdef CONFIG_ETH_SPI_ETHERNET_W5500
    case MAC_CHIP_W5500: {
      eth_w5500_config_t w5500_config = ETH_W5500_DEFAULT_CONFIG(spi_host, &spi_config);
      w5500_config.int_gpio_num = int_num;
      mac = esp_eth_mac_new_w5500(&w5500_config, &mac_config);
      phy = esp_eth_phy_new_w5500(&phy_config);
      break;
    }
#endif
  }
  if (!phy || !mac) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    if (phy) phy->del(phy);
    if (mac) mac->del(mac);
    return Primitive::os_error(ESP_ERR_INVALID_ARG, process);
  }

  esp_eth_config_t config = ETH_DEFAULT_CONFIG(mac, phy);
  esp_eth_handle_t eth_handle = NULL;
  esp_err_t err = esp_eth_driver_install(&config, &eth_handle);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    phy->del(phy);
    mac->del(mac);
    return Primitive::os_error(err, process);
  }

  uint8 mac_addr[6];
  ESP_ERROR_CHECK(esp_read_mac(mac_addr, ESP_MAC_ETH));
  ESP_ERROR_CHECK(esp_eth_ioctl(eth_handle, ETH_CMD_S_MAC_ADDR, mac_addr));

  esp_eth_netif_glue_handle_t netif_glue = esp_eth_new_netif_glue(eth_handle);
  // Attach Ethernet driver to TCP/IP stack.
  err = esp_netif_attach(netif, netif_glue);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    phy->del(phy);
    mac->del(mac);
    return Primitive::os_error(err, process);
  }

  EthernetResourceGroup* resource_group = _new EthernetResourceGroup(
      process, SystemEventSource::instance(), id, mac, phy, netif, eth_handle, netif_glue);
  if (!resource_group) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_del_netif_glue(netif_glue));
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    phy->del(phy);
    mac->del(mac);
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(EthernetResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(connect) {
  ARGS(EthernetResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  EthernetEvents* ethernet = _new EthernetEvents(group);
  if (ethernet == null) FAIL(MALLOC_FAILED);

  group->register_resource(ethernet);
  group->connect();

  proxy->set_external_address(ethernet);
  return proxy;
}

PRIMITIVE(setup_ip) {
  ARGS(EthernetResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  EthernetIpEvents* ip_events = _new EthernetIpEvents(group);
  if (ip_events == null) FAIL(MALLOC_FAILED);

  group->register_resource(ip_events);

  proxy->set_external_address(ip_events);
  return proxy;
}


PRIMITIVE(disconnect) {
  ARGS(EthernetResourceGroup, group, EthernetEvents, ethernet);

  group->unregister_resource(ethernet);

  return process->null_object();
}

PRIMITIVE(get_ip) {
  ARGS(EthernetIpEvents, ip);

  uint32 address = ip->ip_address();
  if (address == 0) return process->null_object();

  ByteArray* result = process->object_heap()->allocate_internal_byte_array(4);
  if (!result) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  Utils::write_unaligned_uint32_le(bytes.address(), address);
  return result;
}

PRIMITIVE(set_hostname) {
  ARGS(EthernetResourceGroup, group, cstring, hostname);

  if (strlen(hostname) > 32) FAIL(INVALID_ARGUMENT);

  esp_err_t err = group->set_hostname(hostname);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

} // namespace toit

#endif // defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_ETHERNET)

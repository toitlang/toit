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

#if defined(TOIT_FREERTOS) && defined(CONFIG_TOIT_ENABLE_ETHERNET)

#include <esp_eth.h>

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
  MAC_CHIP_W5500    = 1,
};

enum {
  PHY_CHIP_IP101    = 1,
  PHY_CHIP_LAN8720  = 2,
};

const int kInvalidEthernet = -1;

// Only allow one instance of WiFi running.
ResourcePool<int, kInvalidEthernet> ethernet_pool(
  0
);

class EthernetResourceGroup : public ResourceGroup {
 public:
  TAG(EthernetResourceGroup);
  EthernetResourceGroup(Process* process, SystemEventSource* event_source, int id,
                        esp_netif_t* netif, esp_eth_handle_t eth_handle,
                        esp_eth_netif_glue_handle_t netif_glue)
      : ResourceGroup(process, event_source)
      , id_(id)
      , netif_(netif)
      , eth_handle_(eth_handle)
      , netif_glue_(netif_glue) {}

  void connect() {
    ESP_ERROR_CHECK(esp_eth_start(eth_handle_));
  }

  ~EthernetResourceGroup() {
    ESP_ERROR_CHECK(esp_eth_stop(eth_handle_));
    ESP_ERROR_CHECK(esp_eth_clear_default_handlers(eth_handle_));
    ESP_ERROR_CHECK(esp_eth_del_netif_glue(netif_glue_));
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle_));
    esp_netif_destroy(netif_);
    ethernet_pool.put(id_);
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state);

 private:
  int id_;
  esp_netif_t *netif_;
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
    clear_ip();
  }

  const char* ip() {
    return ip_;
  }

  void update_ip(uint32 addr) {
    sprintf(ip_, "%d.%d.%d.%d",
            (addr >> 0) & 0xff,
            (addr >> 8) & 0xff,
            (addr >> 16) & 0xff,
            (addr >> 24) & 0xff);
  }

  void clear_ip() {
    memset(ip_, 0, sizeof(ip_));
  }

 private:
  friend class EthernetResourceGroup;
  char ip_[16];
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
        static_cast<EthernetIpEvents*>(resource)->update_ip(event->ip_info.ip.addr);
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

PRIMITIVE(init_esp32) {
  ARGS(int, phy_chip, int, phy_addr, int, phy_reset_num, int, mdc_num, int, mdio_num)

#if CONFIG_IDF_TARGET_ESP32C3 || CONFIG_IDF_TARGET_ESP32S3 || CONFIG_IDF_TARGET_ESP32S2
  return Primitive::os_error(ESP_FAIL, process);
#else

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = ethernet_pool.any();
  if (id == kInvalidEthernet) OUT_OF_BOUNDS;

  esp_netif_config_t cfg = ESP_NETIF_DEFAULT_ETH();
  esp_netif_t *netif = esp_netif_new(&cfg);
  if (!netif) {
    ethernet_pool.put(id);
    MALLOC_FAILED;
  }

  // Init MAC and PHY configs to default.
  eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
  eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();

  phy_config.phy_addr = phy_addr;
  phy_config.reset_gpio_num = phy_reset_num;
  mac_config.smi_mdc_gpio_num = mdc_num;
  mac_config.smi_mdio_gpio_num = mdio_num;

  // TODO(anders): If phy initialization fails, we're leaking this.
  esp_eth_mac_t* mac = esp_eth_mac_new_esp32(&mac_config);

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
      phy = esp_eth_phy_new_lan8720(&phy_config);
      break;
  }
  if (!phy) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    // TODO(anders): Hmmm, cannot figure out to de-init the mac part.
    return Primitive::os_error(ESP_ERR_INVALID_ARG, process);
  }

  esp_eth_config_t config = ETH_DEFAULT_CONFIG(mac, phy);
  esp_eth_handle_t eth_handle = NULL;
  esp_err_t err = esp_eth_driver_install(&config, &eth_handle);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    // TODO(anders): Ditto, deinit mac and phy.
    return Primitive::os_error(err, process);
  }

  esp_eth_netif_glue_handle_t netif_glue = esp_eth_new_netif_glue(eth_handle);
  // Attach Ethernet driver to TCP/IP stack.
  err = esp_netif_attach(netif, netif_glue);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    return Primitive::os_error(err, process);
  }

  EthernetResourceGroup* resource_group = _new EthernetResourceGroup(
    process, SystemEventSource::instance(), id, netif, eth_handle, netif_glue);
  if (!resource_group) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_del_netif_glue(netif_glue));
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    MALLOC_FAILED;
  }

  proxy->set_external_address(resource_group);
  return proxy;
#endif
}


PRIMITIVE(init_spi) {
  ARGS(int, mac_chip, SpiDevice, spi_device, int, int_num)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = ethernet_pool.any();
  if (id == kInvalidEthernet) OUT_OF_BOUNDS;

  esp_netif_config_t cfg = ESP_NETIF_DEFAULT_ETH();
  esp_netif_t *netif = esp_netif_new(&cfg);
  if (!netif) {
    ethernet_pool.put(id);
    MALLOC_FAILED;
  }

  // Init MAC and PHY configs to default.
  eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
  mac_config.smi_mdc_gpio_num = -1;
  mac_config.smi_mdio_gpio_num = -1;
  eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
  phy_config.reset_gpio_num = -1;

  esp_eth_mac_t* mac = null;
  esp_eth_phy_t* phy = null;
  switch (mac_chip) {
    case MAC_CHIP_W5500: {
      eth_w5500_config_t w5500_config = ETH_W5500_DEFAULT_CONFIG(spi_device->handle());
      w5500_config.int_gpio_num = int_num;
      mac = esp_eth_mac_new_w5500(&w5500_config, &mac_config);
      phy = esp_eth_phy_new_w5500(&phy_config);
      break;
    }
  }
  if (!phy || !mac) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    return Primitive::os_error(ESP_ERR_INVALID_ARG, process);
  }

  esp_eth_config_t config = ETH_DEFAULT_CONFIG(mac, phy);
  esp_eth_handle_t eth_handle = NULL;
  esp_err_t err = esp_eth_driver_install(&config, &eth_handle);
  if (err != ESP_OK) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    // TODO(anders): Ditto, deinit mac and phy.
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
    return Primitive::os_error(err, process);
  }

  EthernetResourceGroup* resource_group = _new EthernetResourceGroup(
    process, SystemEventSource::instance(), id, netif, eth_handle, netif_glue);
  if (!resource_group) {
    ethernet_pool.put(id);
    esp_netif_destroy(netif);
    ESP_ERROR_CHECK(esp_eth_del_netif_glue(netif_glue));
    ESP_ERROR_CHECK(esp_eth_driver_uninstall(eth_handle));
    MALLOC_FAILED;
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(EthernetResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(EthernetResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  EthernetEvents* ethernet = _new EthernetEvents(group);
  if (ethernet == null) MALLOC_FAILED;

  group->register_resource(ethernet);
  group->connect();

  proxy->set_external_address(ethernet);
  return proxy;
}

PRIMITIVE(setup_ip) {
  ARGS(EthernetResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  EthernetIpEvents* ip_events = _new EthernetIpEvents(group);
  if (ip_events == null) MALLOC_FAILED;

  group->register_resource(ip_events);

  proxy->set_external_address(ip_events);
  return proxy;
}


PRIMITIVE(disconnect) {
  ARGS(EthernetResourceGroup, group, EthernetEvents, ethernet);

  group->unregister_resource(ethernet);

  return process->program()->null_object();
}

PRIMITIVE(get_ip) {
  ARGS(EthernetIpEvents, ip);
  return process->allocate_string_or_error(ip->ip());
}


} // namespace toit

#endif // defined(TOIT_FREERTOS) && defined(CONFIG_TOIT_ENABLE_ETHERNET)

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

#include <esp_netif.h>

#elif defined(TOIT_USE_LWIP)

#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef TOIT_USE_LWIP

#include <linux/if.h>
#include <linux/if_tun.h>

#include "tapif_toit.h"

#include <lwip/api.h>
#include <lwip/dhcp.h>
#include <lwip/prot/dhcp.h>
#include <lwip/etharp.h>
#include <lwip/init.h>
#include <lwip/init.h>
#include <lwip/netif.h>
#include <lwip/snmp.h>
#include <lwip/stats.h>
#include <lwip/tcpip.h>

#endif  // TOIT_USE_LWIP
#endif  // TOIT_FREERTOS

#include "../flags.h"
#include "../heap_report.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../process.h"

#include "lwip_esp32.h"

namespace toit {

bool needs_gc = false;

#if defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)

static bool is_toit_error(int err) {
  return FIRST_TOIT_ERROR >= err && err >= LAST_TOIT_ERROR;
}

String* lwip_strerror(Process* process, err_t err) {
  // Normal codes returned by LWIP, but LWIP does not have string versions
  // unless it is compiled with debug options.
  static const char* error_names[] = {
             "OK",                       /* ERR_OK          0  */
             "Out of memory (lwip)",     /* ERR_MEM        -1  */
             "Buffer error",             /* ERR_BUF        -2  */
             "Timeout",                  /* ERR_TIMEOUT    -3  */
             "Routing problem",          /* ERR_RTE        -4  */
             "Operation in progress",    /* ERR_INPROGRESS -5  */
             "Illegal value",            /* ERR_VAL        -6  */
             "Operation would block",    /* ERR_WOULDBLOCK -7  */
             "Address in use",           /* ERR_USE        -8  */
             "Already connecting",       /* ERR_ALREADY    -9  */
             "Conn already established", /* ERR_ISCONN     -10 */
             "Connection aborted",       /* ERR_ABRT       -11 */
             "Connection reset",         /* ERR_RST        -12 */
             "Connection closed",        /* ERR_CLSD       -13 */
             "Connection closed",        /* ERR_CONN       -14 */
             "Illegal argument",         /* ERR_ARG        -15 */
             "Low-level netif error",    /* ERR_IF         -16 */
  };

  static const char* custom_strerr[] = {
             "Host name lookup failure"                 /* ERR_NAME_LOOKUP_FAILURE -126  */
             "Connection closed due to memory pressure" /* ERR_MEM_NON_RECOVERABLE -127 */
  };

  const char* str = "Unknown network error";

  if (err <= 0 && static_cast<unsigned>(-err) < sizeof(error_names) / sizeof(error_names[0])) {
    str = error_names[-err];
  } else if (is_toit_error(err)) {
    str = custom_strerr[err - FIRST_TOIT_ERROR];
  }
  return process->allocate_string(str);
}

Object* lwip_error(Process* process, err_t err) {
  if (err == ERR_MEM) MALLOC_FAILED;
  String* str = lwip_strerror(process, err);
  if (str == null) ALLOCATION_FAILED;
  return Primitive::mark_as_error(str);
}

LwipEventSource* LwipEventSource::instance_ = null;

MODULE_IMPLEMENTATION(dhcp, MODULE_DHCP)

#ifdef TOIT_USE_LWIP

static dhcp static_dhcp;

PRIMITIVE(wait_for_lwip_dhcp_on_linux) {
  if (Flags::dhcp) {
    fprintf(stderr, "Waiting for DHCP server\n");

    err_t err;
    LwipEventSource::instance()->call_on_thread([&]() -> Object* {
      dhcp_set_struct(&global_netif, &static_dhcp);
      netif_set_up(&global_netif);
      err = dhcp_start(&global_netif);
      return process->program()->null_object();
    });
    if (err != ERR_OK) {
      return lwip_error(process, err);
    }

    while (netif_dhcp_data(&global_netif)->state != DHCP_STATE_BOUND) {
      usleep(1000);
    }

    fprintf(stderr, "IP: %d.%d.%d.%d\n",
        ip4_addr1(&global_netif.ip_addr),
        ip4_addr2(&global_netif.ip_addr),
        ip4_addr3(&global_netif.ip_addr),
        ip4_addr4(&global_netif.ip_addr));
  } else {
    // Wait until we know which tap device the low level driver could register.  This
    // gives us the MAC address and the 'static' (ie non-DHCP) IP address for the subnet.
    while (ip_addr_offset == -1) {
      usleep(1000);
    }
    uint8_t byte1 = 172;
    uint8_t byte2 = 27;
    uint8_t byte3 = 128 + (ip_addr_offset >> 8);
    uint8_t byte4 = ip_addr_offset &0xff;
    fprintf(stderr, "Set IP address %d.%d.%d.%d, mask 255.255.0.0, gw %d.%d.0.1\n", byte1, byte2, byte3, byte4, byte1, byte2);
    LwipEventSource::instance()->call_on_thread([&]() -> Object* {
      ip4_addr_t ip, netmask, gateway;
      ip4_addr_set_u32(&ip, (byte1 << 0) | (byte2 << 8) | (byte3 << 16) | (byte4 << 24));  // IP:      172.27.128.xx
      ip4_addr_set_u32(&netmask, 0x0000FFFF);                                              // Netmask: 255.255.0.0
      ip4_addr_set_u32(&gateway, (byte1 << 0) | (byte2 << 8) | (1 << 24));  // Gateway: 172.27.0.1
      netif_set_ipaddr(&global_netif, &ip);
      netif_set_netmask(&global_netif, &netmask);
      netif_set_gw(&global_netif, &gateway);
      return 0;
    });
  }
  return process->program()->null_object();
}

#else

PRIMITIVE(wait_for_lwip_dhcp_on_linux) {
  return process->program()->null_object();
}

#endif


LwipEventSource::LwipEventSource()
    : EventSource("LwIP", 1)
    , call_done_(OS::allocate_condition_variable(mutex())) {
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + LWIP_MALLOC_TAG);
#if defined(TOIT_FREERTOS)
  // Create the LWIP thread.
  esp_netif_init();
#else
  // LWIP defaults to using rand() to get randomness, but that returns the same
  // numbers (eg for local ports) every time, unless it is seeded.  That can
  // cause TCP connections to fail to establish.
  srand(time(nullptr) + 97 * getpid());

  sys_sem_t init_semaphore;
  sys_sem_new(&init_semaphore, 0);
  tcpip_init(&init_on_tcpip_thread, &init_semaphore);

  sys_arch_sem_wait(&init_semaphore, 0);
  sys_sem_free(&init_semaphore);
#endif

  ASSERT(instance_ == null);
  instance_ = this;

  call_on_thread([&]() -> Object* {
    Thread::ensure_system_thread();
    OS::set_heap_tag(ITERATE_CUSTOM_TAGS + LWIP_MALLOC_TAG);
    return Smi::from(0);
  });
}

LwipEventSource::~LwipEventSource() {
  instance_ = null;
  OS::dispose(call_done_);
}

void LwipEventSource::on_thread(void* arg) {
  CallContext* call = unvoid_cast<CallContext*>(arg);
  Object* result = call->func();

  auto lwip = instance();
  Locker locker(lwip->mutex());
  call->result = result;
  call->done = true;

  // We must signal all waiters to make sure we don't end
  // up in a situation where the LWIP calls are done in a
  // different order than the waiting.
  OS::signal_all(lwip->call_done());
}

#else // defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)

MODULE_IMPLEMENTATION(dhcp, MODULE_DHCP)

PRIMITIVE(wait_for_lwip_dhcp_on_linux) {
  return process->program()->null_object();
}

#endif // defined(TOIT_FREERTOS) || defined(TOIT_USE_LWIP)

} // namespace toit

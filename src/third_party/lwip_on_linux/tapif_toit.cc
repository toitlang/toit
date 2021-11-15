/*
 * Copyright (c) 2001-2003 Swedish Institute of Computer Science.
 *
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
 * SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
 * OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * This file is part of the lwIP TCP/IP stack.
 *
 * Author: Adam Dunkels <adam@sics.se>
 *
 */

/*
 * This file is adapted from contrib/ports/unix/port/netif/tapif.c in the LWIP
 * distribution.
 */ 

#ifdef TOIT_USE_LWIP

#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <lwip/api.h>
#include <lwip/dhcp.h>
#include <lwip/dns.h>
#include <lwip/etharp.h>
#include <lwip/init.h>
#include <lwip/init.h>
#include <lwip/netif.h>
#include <lwip/prot/dhcp.h>
#include <lwip/snmp.h>
#include <lwip/tcpip.h>

#include "tapif_toit.h"

namespace toit {

struct Tapif {
 public:
  Tapif() : fd(-1) {}
  int fd;
};

netif global_netif;
static Tapif static_tapif;

static err_t my_low_level_output(netif* interface, pbuf* p) {
  Tapif* tapif = reinterpret_cast<Tapif*>(interface->state);
  const int BUF_SIZE = 1518;

  char buffer[BUF_SIZE];
  ssize_t written;

  ssize_t len = p->tot_len;

  if (len > BUF_SIZE) return ERR_IF;

  pbuf_copy_partial(p, buffer, len, 0);

  written = write(tapif->fd, buffer, len);
  if (written < len) {
    return ERR_IF;
  }

  return ERR_OK;
}

int ip_addr_offset = -1;

static err_t my_tapif_init(netif* interface) {
  interface->state = &static_tapif;

  MIB2_INIT_NETIF(interface, snmp_ifType_other, 100000000);

  interface->name[0] = 't';
  interface->name[1] = 'p';
  interface->output = etharp_output;
  interface->linkoutput = my_low_level_output;
  interface->mtu = 1500;

  // Low level init.

  static_tapif.fd = open("/dev/net/tun", O_RDWR);
  if (static_tapif.fd < 0) {
    perror("/dev/net/tun");
    exit(1);
  }

  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));

  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;

  int tap_if;
  bool success = false;
  for (tap_if = 7017; tap_if < 7100; tap_if++) {
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "tap%d", tap_if);
    int result = ioctl(static_tapif.fd, TUNSETIFF, &ifr);
    if (result == 0) {
      success = true;
      break;
    } else if (errno != EBUSY) {
      perror(ifr.ifr_name);
      exit(1);
    }
  }

  if (!success) {
    fprintf(stderr, "Did you remember to run tools/tap-networking.sh?\n");
    perror("tap7017...");
    exit(1);
  }

  // Make a MAC address that depends on the tap interface number so that we don't get
  // MAC clashes in the virtual switch they are all connected to.
  interface->hwaddr[0] = 0x02;
  interface->hwaddr[1] = 0x12;
  interface->hwaddr[2] = 0x70;
  interface->hwaddr[3] = 0x17;
  interface->hwaddr[4] = (tap_if >> 8);
  interface->hwaddr[5] = (tap_if & 0xff);
  interface->hwaddr_len = 6;
  interface->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_IGMP;

  ip_addr_offset = tap_if - 7017;

  netif_set_link_up(interface);

  return ERR_OK;
}

static struct pbuf *
low_level_input(struct netif *netif)
{
  struct pbuf *p;
  u16_t len;
  ssize_t readlen;
  char buf[1518]; /* max packet size including VLAN excluding CRC */
  Tapif *tapif = reinterpret_cast<Tapif *>(netif->state);

  /* Obtain the size of the packet and put it into the "len"
     variable. */
  readlen = read(tapif->fd, buf, sizeof(buf));
  if (readlen < 0) {
    perror("read returned -1");
    exit(1);
  }
  len = (u16_t)readlen;

  MIB2_STATS_NETIF_ADD(netif, ifinoctets, len);

  /* We allocate a pbuf chain of pbufs from the pool. */
  p = pbuf_alloc(PBUF_RAW, len, PBUF_POOL);
  if (p != NULL) {
    pbuf_take(p, buf, len);
    /* acknowledge that packet has been read(); */
  } else {
    /* drop packet(); */
    MIB2_STATS_NETIF_INC(netif, ifindiscards);
    LWIP_DEBUGF(NETIF_DEBUG, ("tapif_input: could not allocate pbuf\n"));
  }

  return p;
}

static void
tapif_input(struct netif *netif)
{
  struct pbuf *p = low_level_input(netif);

  if (p == NULL) {
#if LINK_STATS
    LINK_STATS_INC(link.recv);
#endif /* LINK_STATS */
    LWIP_DEBUGF(NETIF_DEBUG, ("tapif_input: low_level_input returned NULL\n"));
    return;
  }

  if (netif->input(p, netif) != ERR_OK) {
    LWIP_DEBUGF(NETIF_DEBUG, ("tapif_input: netif input error\n"));
    pbuf_free(p);
  }
}

static void
tapif_thread(void *arg)
{
  struct netif *netif;
  Tapif *tapif;
  fd_set fdset;
  int ret;

  netif = reinterpret_cast<struct netif *>(arg);
  tapif = reinterpret_cast<Tapif *>(netif->state);

  while(1) {
    FD_ZERO(&fdset);
    FD_SET(tapif->fd, &fdset);

    /* Wait for a packet to arrive. */
    ret = select(tapif->fd + 1, &fdset, NULL, NULL, NULL);

    if(ret == 1) {
      /* Handle incoming packet. */
      tapif_input(netif);
    } else if(ret == -1) {
      perror("tapif_thread: select");
    }
  }
}

void init_on_tcpip_thread(void* closure) {
  sys_sem_t* init_semaphore = reinterpret_cast<sys_sem_t*>(closure);

  ip4_addr_t ipaddr, netmask, gw;

  ip4_addr_set_zero(&gw);
  ip4_addr_set_zero(&ipaddr);
  ip4_addr_set_zero(&netmask);

  netif_add(&global_netif, &ipaddr, &netmask, &gw, nullptr, my_tapif_init, tcpip_input);
  netif_set_default(&global_netif);

  sys_thread_new("tapif_thread", tapif_thread, &global_netif, DEFAULT_THREAD_STACKSIZE, DEFAULT_THREAD_PRIO);

  sys_sem_signal(init_semaphore);
}

} // namespace toit

#endif // defined(TOIT_USE_LWIP)

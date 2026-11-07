// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// Native radio bring-up, independent of the Toit network primitives.
#include <stdio.h>
#include <string.h>
#include "pico/cyw43_arch.h"
#include "pico/cyw43_driver.h"
#include "lwip/udp.h"

static bool initialized;
static bool active;
static struct udp_pcb* socket;
static unsigned round_trip;
static bool pending;
static uint64_t deadline;
static int previous_status = 99;

// Report the initial bus-test reads without modifying the pinned SDK.
extern uint32_t __real_read_reg_u32_swap(void*, uint32_t, uint32_t);
uint32_t __wrap_read_reg_u32_swap(void* self, uint32_t function, uint32_t reg) {
  uint32_t value = __real_read_reg_u32_swap(self, function, reg);
  printf("CYW43 bus test fn=%lu reg=%08lx value=%08lx\n",
      (unsigned long)function, (unsigned long)reg, (unsigned long)value);
  return value;
}

static void stop(void) {
  if (socket) udp_remove(socket);
  socket = NULL;
  active = false;
  pending = false;
}

static void received(void* arg, struct udp_pcb* pcb, struct pbuf* packet,
                     const ip_addr_t* address, u16_t port) {
  (void)arg; (void)pcb; (void)address; (void)port;
  bool valid = pending && packet->tot_len == 512;
  for (unsigned i = 0; valid && i < 512; i++) {
    valid = pbuf_get_at(packet, i) == (uint8_t)(i + round_trip);
  }
  pbuf_free(packet);
  if (!valid) {
    puts("RP2040 native WiFi: FAIL echo payload");
    stop();
    return;
  }
  pending = false;
  if (++round_trip == 32) {
    puts("RP2040 native WiFi/DHCP/UDP smoke: PASS");
    stop();
  }
}

void wifi_probe_start(unsigned divider) {
  cyw43_set_pio_clkdiv_int_frac8(divider, 0);
  if (initialized) {
    stop();
    cyw43_arch_deinit();
    initialized = false;
  }
  if (!initialized) {
    if (cyw43_arch_init()) {
      puts("RP2040 native WiFi: FAIL radio init");
      return;
    }
    initialized = true;
    cyw43_arch_enable_sta_mode();
  }
  stop();
  round_trip = 0;
  previous_status = 99;
  // These credentials belong only to the accompanying isolated test AP.
  int result = cyw43_arch_wifi_connect_async("toit-rp2040-test", "pico-bringup-test",
                                            CYW43_AUTH_WPA2_AES_PSK);
  if (result) {
    printf("RP2040 native WiFi: FAIL connect %d\n", result);
    return;
  }
  active = true;
  deadline = time_us_64() + 30000000;
}

void wifi_probe_poll(void) {
  if (!initialized) return;
  cyw43_arch_poll();
  if (!active) return;
  int status = cyw43_tcpip_link_status(&cyw43_state, CYW43_ITF_STA);
  if (status != previous_status) {
    printf("RP2040 native WiFi link=%d\n", status);
    previous_status = status;
  }
  if (status < 0 || time_us_64() >= deadline) {
    printf("RP2040 native WiFi: FAIL link=%d timeout=%u\n", status,
           time_us_64() >= deadline);
    stop();
    return;
  }
  if (status != CYW43_LINK_UP || pending) return;
  if (!socket) {
    struct netif* interface = &cyw43_state.netif[CYW43_ITF_STA];
    printf("RP2040 native WiFi IP=%s\n", ip4addr_ntoa(netif_ip4_addr(interface)));
    socket = udp_new();
    if (!socket) {
      puts("RP2040 native WiFi: FAIL UDP allocation");
      stop();
      return;
    }
    ip_addr_t peer;
    ip_addr_copy_from_ip4(peer, *netif_ip4_gw(interface));
    if (udp_connect(socket, &peer, 4242) != ERR_OK) {
      puts("RP2040 native WiFi: FAIL UDP connect");
      stop();
      return;
    }
    udp_recv(socket, received, NULL);
  }
  struct pbuf* packet = pbuf_alloc(PBUF_TRANSPORT, 512, PBUF_RAM);
  if (!packet) {
    puts("RP2040 native WiFi: FAIL packet allocation");
    stop();
    return;
  }
  for (unsigned i = 0; i < 512; i++) ((uint8_t*)packet->payload)[i] = i + round_trip;
  err_t result = udp_send(socket, packet);
  pbuf_free(packet);
  if (result != ERR_OK) {
    printf("RP2040 native WiFi: FAIL send %d\n", result);
    stop();
    return;
  }
  pending = true;
  deadline = time_us_64() + 5000000;
}

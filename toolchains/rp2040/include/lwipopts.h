// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#if PICO_CYW43_ARCH_FREERTOS
#define NO_SYS 0
#else
#define NO_SYS 1
#endif
#define LWIP_SOCKET 0
#define LWIP_NETCONN 0
#define LWIP_DHCP 1
#define LWIP_DNS 1
#define LWIP_RAW 1
#define LWIP_IGMP 1
#define LWIP_NETIF_HOSTNAME 1
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK 1
#define MEM_ALIGNMENT 4
#define MEM_SIZE (16 * 1024)
#define TCP_MSS 1460
#define TCP_WND (4 * TCP_MSS)
#define TCP_SND_BUF (4 * TCP_MSS)
#define MEMP_NUM_TCP_SEG 32
#define PBUF_POOL_SIZE 16
#define LWIP_CHKSUM_ALGORITHM 3
#define LWIP_DHCP_DOES_ACD_CHECK 0
#define LWIP_STATS 0
#define LWIP_PROVIDE_ERRNO 1
#define TCPIP_THREAD_STACKSIZE 2048
#define TCPIP_THREAD_PRIO 2
#define TCPIP_MBOX_SIZE 16
#define DEFAULT_UDP_RECVMBOX_SIZE 8
#define DEFAULT_TCP_RECVMBOX_SIZE 8
#define DEFAULT_ACCEPTMBOX_SIZE 8

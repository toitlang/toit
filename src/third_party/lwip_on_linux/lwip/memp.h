/**
 * @file
 * Memory pool API
 */

/*
 * Copyright (c) 2001-2004 Swedish Institute of Computer Science.
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

#ifndef LWIP_HDR_MEMP_H
#define LWIP_HDR_MEMP_H

#include "lwip/opt.h"

#include "lwip/priv/memp_priv.h"

#ifdef __cplusplus
extern "C" {
#endif

/* run once with empty definition to handle all custom includes in lwippools.h */
#define LWIP_MEMPOOL(name,num,size,desc)
#include "lwip/priv/memp_std.h"

/** Create the list of all memory pools managed by memp. MEMP_MAX represents a NULL pool at the end */
typedef enum {
#define LWIP_MEMPOOL(name,num,size,desc)  MEMP_##name,
#include "lwip/priv/memp_std.h"
  MEMP_MAX
} memp_t;

#define LWIP_MEMPOOL_DECLARE(name, num, size, desc)                                \
  LWIP_DECLARE_MEMORY_ALIGNED(memp_memory_ ## name ## base_, ((num) * (MEMP_SIZE + MEMP_ALIGN_SIZE(size)))); \
                                                                                   \
  LWIP_MEMPOOL_DECLARE_STATS_INSTANCE(memp_stats_ ## name)                         \
                                                                                   \
  static struct memp *memp_tab_ ## name;                                           \
                                                                                   \
  const struct memp_desc memp_ ## name = {                                         \
    DECLARE_LWIP_MEMPOOL_DESC(desc)                                                \
    LWIP_MEMPOOL_DECLARE_STATS_REFERENCE(memp_stats_ ## name)                      \
    LWIP_MEM_ALIGN_SIZE(size),                                                     \
    (num),                                                                         \
    memp_memory_ ## name ## base_,                                                 \
    &memp_tab_ ## name                                                             \
  };



void *memp_malloc(memp_t type);
void memp_free(memp_t type, void *mem);
void memp_init();

#ifdef __cplusplus
}
#endif

#endif /* LWIP_HDR_MEMP_H */

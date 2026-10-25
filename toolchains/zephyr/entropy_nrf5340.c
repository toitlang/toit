// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// Register sequence: nRF5340 Product Specification, CRYPTOCELL/RNG engine.
// https://docs.nordicsemi.com/r/bundle/ps_nrf5340/page/cryptocell.html
#define DT_DRV_COMPAT nordic_nrf_cc312_rng
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/entropy.h>
#include <nrfx.h>
#include <string.h>

static K_MUTEX_DEFINE(entropy_mutex);
static uint32_t previous[6];
static bool have_previous;

static int collect(uint32_t output[6]) {
  const uint32_t samples[] = {NRF_FICR_S->TRNG90B.ROSC1, NRF_FICR_S->TRNG90B.ROSC2,
                            NRF_FICR_S->TRNG90B.ROSC3, NRF_FICR_S->TRNG90B.ROSC4};
  unsigned oscillator = 4;
  uint32_t count = UINT32_MAX;
  for (unsigned i = 0; i < 4; i++) {
    if (samples[i] != 0 && samples[i] < count) { oscillator = i; count = samples[i]; }
  }
  if (oscillator == 4) return -ENODATA;
  NRF_CRYPTOCELL_S->ENABLE = CRYPTOCELL_ENABLE_ENABLE_Enabled;
  NRF_CC_RNG_S->RNG_CLK = 1;
  NRF_CC_RNG_S->RNG_SW_RESET = 1;
  int64_t deadline = k_uptime_get() + 100;
  do {
    NRF_CC_RNG_S->RNG_CLK = 1;
    NRF_CC_RNG_S->SAMPLE_CNT = count;
    if (k_uptime_get() >= deadline) return -ETIMEDOUT;
  } while (NRF_CC_RNG_S->SAMPLE_CNT != count);
  NRF_CC_RNG_S->RNG_IMR = UINT32_MAX;
  NRF_CC_RNG_S->RNG_ICR = UINT32_MAX;
  NRF_CC_RNG_S->TRNG_DEBUG = 0;  // Keep all hardware health tests enabled.
  NRF_CC_RNG_S->TRNG_CONFIG = oscillator;
  NRF_CC_RNG_S->NOISE_SOURCE = 1;
  const uint32_t errors = CC_RNG_RNG_ISR_AUTOCORR_ERR_INT_Msk |
      CC_RNG_RNG_ISR_CRNGT_ERR_INT_Msk | CC_RNG_RNG_ISR_VNC_ERR_INT_Msk;
  for (;;) {
    uint32_t status = NRF_CC_RNG_S->RNG_ISR;
    if (status & errors) return -EIO;
    if (status & CC_RNG_RNG_ISR_EHR_VALID_INT_Msk) break;
    if (k_uptime_get() >= deadline) return -ETIMEDOUT;
    k_msleep(1);
  }
  for (unsigned i = 0; i < 6; i++) output[i] = NRF_CC_RNG_S->EHR_DATA[i];
  if (NRF_CC_RNG_S->RNG_ISR & errors) return -EIO;
  if (have_previous && memcmp(output, previous, sizeof(previous)) == 0) return -EIO;
  memcpy(previous, output, sizeof(previous));
  have_previous = true;
  return 0;
}

static int get_entropy(const struct device* device, uint8_t* output, uint16_t length) {
  ARG_UNUSED(device);
  if (k_is_in_isr()) return -EWOULDBLOCK;
  k_mutex_lock(&entropy_mutex, K_FOREVER);
  int result = 0;
  while (length) {
    uint32_t words[6];
    result = collect(words);
    NRF_CC_RNG_S->NOISE_SOURCE = 0;
    if (result) break;
    size_t size = MIN(length, sizeof(words));
    memcpy(output, words, size);
    memset(words, 0, sizeof(words));
    output += size;
    length -= size;
  }
  NRF_CC_RNG_S->RNG_CLK = 0;
  NRF_CRYPTOCELL_S->ENABLE = 0;
  k_mutex_unlock(&entropy_mutex);
  return result;
}
static DEVICE_API(entropy, entropy_api) = { .get_entropy = get_entropy };
DEVICE_DT_INST_DEFINE(0, NULL, NULL, NULL, NULL, POST_KERNEL,
                      CONFIG_KERNEL_INIT_PRIORITY_DEVICE, &entropy_api);

// Copyright (C) 2023 Toitware ApS.
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

// We can't include 'top.h' in this file.
// Therefore we don't test for `TOIT_ESP32` but for `ESP_PLATFORM`.
#if defined(ESP_PLATFORM)

#include "esp_attr.h"
#include "uart_esp32_hal.h"
#include "hal/uart_hal.h"

uart_hal_handle_t uart_toit_hal_init(uart_port_t port) {
  uart_hal_handle_t handle = malloc(sizeof(uart_hal_t));
  if (!handle) return NULL;

  uart_hal_context_t* hal = malloc(sizeof(uart_hal_context_t));
  if (!hal) {
    free(handle);
    return NULL;
  }

  handle->hal = hal;
  hal->dev = UART_LL_GET_HW(port);

  handle->interrupt_mask[UART_TOIT_INTR_RXFIFO_FULL]  = UART_INTR_RXFIFO_FULL;
  handle->interrupt_mask[UART_TOIT_INTR_TXFIFO_EMPTY] = UART_INTR_TXFIFO_EMPTY;
  handle->interrupt_mask[UART_TOIT_INTR_PARITY_ERR]   = UART_INTR_PARITY_ERR;
  handle->interrupt_mask[UART_TOIT_INTR_RXFIFO_OVF]   = UART_INTR_RXFIFO_OVF;
  handle->interrupt_mask[UART_TOIT_INTR_TX_BRK_DONE]  = UART_INTR_TX_BRK_DONE;
  handle->interrupt_mask[UART_TOIT_INTR_TX_DONE]      = UART_INTR_TX_DONE;
  handle->interrupt_mask[UART_TOIT_ALL_INTR_MASK]     = UART_LL_INTR_MASK;
  handle->interrupt_mask[UART_TOIT_INTR_RX_TIMEOUT]   = UART_INTR_RXFIFO_TOUT;
  handle->interrupt_mask[UART_TOIT_INTR_BRK_DET]      = UART_INTR_BRK_DET;

  return handle;
}

void uart_toit_hal_deinit(uart_hal_handle_t hal) {
  free(hal->hal);
  free(hal);
}

#define HAL (uart_hal_context_t*)hal->hal

void uart_toit_hal_set_tx_idle_num(uart_hal_handle_t hal, uint16_t idle_num) {
  uart_hal_set_tx_idle_num(HAL, idle_num);
}

void uart_toit_hal_set_sclk(uart_hal_handle_t hal, uart_sclk_t sclk) {
  uart_hal_set_sclk(HAL, sclk);
}

int uart_get_sclk_freq(uart_sclk_t sclk, uint32_t* out_freq_hz);

void uart_toit_hal_set_baudrate(uart_hal_handle_t hal, uint32_t baud_rate) {
  soc_module_clk_t src_clk;
  uart_hal_get_sclk(HAL, &src_clk);
  uint32_t sclk_frequency;
  uart_get_sclk_freq(src_clk, &sclk_frequency);

  uart_hal_set_baudrate(HAL, baud_rate, sclk_frequency);
}

void uart_toit_hal_set_stop_bits(uart_hal_handle_t hal, uart_stop_bits_t stop_bit) {
  uart_hal_set_stop_bits(HAL, stop_bit);
}

void uart_toit_hal_set_data_bit_num(uart_hal_handle_t hal, uart_word_length_t data_bit) {
  uart_hal_set_data_bit_num(HAL, data_bit);
}

void uart_toit_hal_set_parity(uart_hal_handle_t hal, uart_parity_t parity_mode) {
  uart_hal_set_parity(HAL, parity_mode);
}

void uart_toit_hal_set_hw_flow_ctrl(uart_hal_handle_t hal, uart_hw_flowcontrol_t flow_ctrl, uint8_t rx_thresh) {
  uart_hal_set_hw_flow_ctrl(HAL, flow_ctrl, rx_thresh);
}

void uart_toit_hal_set_rxfifo_full_thr(uart_hal_handle_t hal, uint32_t full_thrhd) {
  uart_hal_set_rxfifo_full_thr(HAL, full_thrhd);
}

void uart_toit_hal_set_txfifo_empty_thr(uart_hal_handle_t hal, uint32_t empty_thrhd) {
  uart_hal_set_txfifo_empty_thr(HAL, empty_thrhd);
}

void uart_toit_hal_set_rx_timeout(uart_hal_handle_t hal, uint8_t timeout) {
  uart_hal_set_rx_timeout(HAL, timeout);
}

void uart_toit_hal_set_mode(uart_hal_handle_t hal, uart_mode_t mode) {
  uart_hal_set_mode(HAL, mode);
}

void uart_toit_hal_inverse_signal(uart_hal_handle_t hal, uint32_t inv_mask) {
  uart_hal_inverse_signal(HAL, inv_mask);
}

void uart_toit_hal_get_baudrate(uart_hal_handle_t hal, uint32_t* baud_rate) {
  soc_module_clk_t src_clk;
  uart_hal_get_sclk(HAL, &src_clk);
  uint32_t sclk_frequency;
  uart_get_sclk_freq(src_clk, &sclk_frequency);

  uart_hal_get_baudrate(HAL, baud_rate, sclk_frequency);
}

#if SOC_UART_REQUIRE_CORE_RESET
void uart_toit_hal_set_reset_core(uart_hal_handle_t hal, bool reset) {
  uart_hal_set_reset_core(HAL, reset);
}
#endif  // SOC_UART_REQUIRE_CORE_RESET

void IRAM_ATTR uart_toit_hal_rxfifo_rst(uart_hal_handle_t hal) {
  uart_hal_rxfifo_rst(HAL);
}

void IRAM_ATTR uart_toit_hal_txfifo_rst(uart_hal_handle_t hal) {
  uart_hal_txfifo_rst(HAL);
}

void IRAM_ATTR uart_toit_hal_tx_break(uart_hal_handle_t hal, uint32_t break_num) {
  uart_hal_tx_break(HAL, break_num);
}

bool IRAM_ATTR uart_toit_hal_is_tx_idle(uart_hal_handle_t hal) {
  return uart_hal_is_tx_idle(HAL);
}

void IRAM_ATTR uart_toit_hal_set_rts(uart_hal_handle_t hal, bool active) {
  uart_hal_set_rts(HAL, active ? 0 : 1);
}

uint32_t IRAM_ATTR uart_toit_hal_get_rxfifo_len(uart_hal_handle_t hal) {
  return uart_hal_get_rxfifo_len(HAL);
}

uint32_t IRAM_ATTR uart_toit_hal_get_txfifo_len(uart_hal_handle_t hal) {
  return uart_hal_get_txfifo_len(HAL);
}

void IRAM_ATTR uart_toit_hal_write_txfifo(uart_hal_handle_t hal, const uint8_t* buf, uint32_t data_size, uint32_t* write_size) {
  uart_hal_write_txfifo(HAL, buf, data_size, write_size);
}

void IRAM_ATTR uart_toit_hal_read_rxfifo(uart_hal_handle_t hal, uint8_t* buf, int* inout_rd_len) {
  uart_hal_read_rxfifo(HAL, buf, inout_rd_len);
}

void IRAM_ATTR uart_toit_hal_ena_intr_mask(uart_hal_handle_t hal, uint32_t mask) {
  uart_hal_ena_intr_mask(HAL, mask);
}

void IRAM_ATTR uart_toit_hal_disable_intr_mask(uart_hal_handle_t hal, uint32_t mask) {
  uart_hal_disable_intr_mask(HAL, mask);
}

uint32_t IRAM_ATTR uart_toit_hal_get_intsts_mask(uart_hal_handle_t hal) {
  return uart_hal_get_intsts_mask(HAL);
}

void IRAM_ATTR uart_toit_hal_clr_intsts_mask(uart_hal_handle_t hal, uint32_t mask) {
  uart_hal_clr_intsts_mask(HAL, mask);
}

#endif

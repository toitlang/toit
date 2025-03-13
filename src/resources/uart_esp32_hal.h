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

#pragma once
#if defined(__FREERTOS__)

#include <hal/uart_types.h>

// This file is purely here to enable calling some low-level C-code defined in header files
// in ESP-IDF. For documentation of almost all the functions, please refer to hal/uart_hal.h.

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  UART_TOIT_INTR_RXFIFO_FULL = 0,   // The RxFifo is over its threshold
  UART_TOIT_INTR_TXFIFO_EMPTY,      // The TxFifo is under its threshold
  UART_TOIT_INTR_PARITY_ERR,        // Parity error
  UART_TOIT_INTR_RXFIFO_OVF,        // RxFifo overflow, not emptied fast enough
  UART_TOIT_INTR_TX_BRK_DONE,       // Transfer break completed
  UART_TOIT_INTR_TX_DONE,           // Transfer completed
  UART_TOIT_INTR_RX_TIMEOUT,        // The RxFifo has data, not over its threshold, but some time since last byte
  UART_TOIT_INTR_BRK_DET,           // Break detected
  UART_TOIT_ALL_INTR_MASK,          // All interrupt bits
  UART_TOIT_INTR_MAX
} uart_toit_interrupt_index_t;

typedef struct {
  void* hal;
  uint32_t interrupt_mask[UART_TOIT_INTR_MAX];
} uart_hal_t;

typedef uart_hal_t* uart_hal_handle_t;

// Initialize (allocate) the right hal structure.
uart_hal_handle_t uart_toit_hal_init(uart_port_t port);

// De-initialize (free) the hal structure.
void uart_toit_hal_deinit(uart_hal_handle_t hal);

// The rest of the functions have a corresponding declaration in hal/uart_hal.h
void uart_toit_hal_set_sclk(uart_hal_handle_t hal, uart_sclk_t sclk);
void uart_toit_hal_get_baudrate(uart_hal_handle_t hal, uint32_t* baud_rate);
void uart_toit_hal_set_baudrate(uart_hal_handle_t hal, uint32_t baud_rate);
void uart_toit_hal_set_stop_bits(uart_hal_handle_t hal, uart_stop_bits_t stop_bit);
void uart_toit_hal_set_tx_idle_num(uart_hal_handle_t hal, uint16_t idle_num);
void uart_toit_hal_set_data_bit_num(uart_hal_handle_t hal, uart_word_length_t data_bit);
void uart_toit_hal_set_parity(uart_hal_handle_t hal, uart_parity_t parity_mode);
void uart_toit_hal_set_hw_flow_ctrl(uart_hal_handle_t hal, uart_hw_flowcontrol_t flow_ctrl, uint8_t rx_thresh);
void uart_toit_hal_set_rxfifo_full_thr(uart_hal_handle_t hal, uint32_t full_thrhd);
void uart_toit_hal_set_txfifo_empty_thr(uart_hal_handle_t hal, uint32_t empty_thrhd);
void uart_toit_hal_set_rx_timeout(uart_hal_handle_t hal, uint8_t timeout);
void uart_toit_hal_set_reset_core(uart_hal_handle_t hal, bool reset);
void uart_toit_hal_set_mode(uart_hal_handle_t hal, uart_mode_t mode);
void uart_toit_hal_inverse_signal(uart_hal_handle_t hal, uint32_t inv_mask);

// ISR safe operations.
void uart_toit_hal_rxfifo_rst(uart_hal_handle_t hal);
void uart_toit_hal_txfifo_rst(uart_hal_handle_t hal);
void uart_toit_hal_tx_break(uart_hal_handle_t hal, uint32_t break_num);
void uart_toit_hal_set_rts(uart_hal_handle_t hal, bool active);
bool uart_toit_hal_is_tx_idle(uart_hal_handle_t hal);
uint32_t uart_toit_hal_get_rxfifo_len(uart_hal_handle_t hal);
uint32_t uart_toit_hal_get_txfifo_len(uart_hal_handle_t hal);
void uart_toit_hal_write_txfifo(uart_hal_handle_t hal, const uint8_t* buf, uint32_t data_size, uint32_t* write_size);
void uart_toit_hal_read_rxfifo(uart_hal_handle_t hal, uint8_t* buf, int* inout_rd_len);
void uart_toit_hal_ena_intr_mask(uart_hal_handle_t hal, uint32_t mask);
void uart_toit_hal_disable_intr_mask(uart_hal_handle_t hal, uint32_t mask);
uint32_t uart_toit_hal_get_intsts_mask(uart_hal_handle_t hal);
void uart_toit_hal_clr_intsts_mask(uart_hal_handle_t hal, uint32_t mask);

#ifdef __cplusplus
}
#endif

#endif

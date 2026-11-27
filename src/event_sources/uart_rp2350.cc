// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_RP2350

#include "uart_rp2350.h"

#include "hardware/irq.h"
#include "hardware/uart.h"

namespace toit {

Rp2350UartEventSource* Rp2350UartEventSource::instance_ = null;
Rp2350UartEventResource* volatile Rp2350UartEventSource::active_[2] = {};
uint32_t Rp2350UartEventSource::pending_[2] = {};
uint32_t Rp2350UartEventSource::tx_poll_mask_ = 0;

Rp2350UartEventSource::Rp2350UartEventSource()
    : Rp2350PeripheralEventSource("RP2350 UART") {
  ASSERT(instance_ == null);
  instance_ = this;

  irq_set_exclusive_handler(UART0_IRQ, uart0_interrupt);
  irq_set_exclusive_handler(UART1_IRQ, uart1_interrupt);
  irq_set_priority(UART0_IRQ, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_priority(UART1_IRQ, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_enabled(UART0_IRQ, false);
  irq_set_enabled(UART1_IRQ, false);

  Rp2350EventDispatcher::instance()->attach(Rp2350EventDispatcher::UART, this);
}

Rp2350UartEventSource::~Rp2350UartEventSource() {
  irq_set_enabled(UART0_IRQ, false);
  irq_set_enabled(UART1_IRQ, false);
  irq_remove_handler(UART0_IRQ, uart0_interrupt);
  irq_remove_handler(UART1_IRQ, uart1_interrupt);
  instance_ = null;
  Rp2350EventDispatcher::instance()->detach(Rp2350EventDispatcher::UART, this);
}

void Rp2350UartEventSource::on_register_resource(
    Locker& locker, Resource* resource) {
  USE(locker);
  auto uart = static_cast<Rp2350UartEventResource*>(resource);
  int id = uart->uart_id();
  ASSERT(id >= 0 && id < NUM_UARTS);
  ASSERT(active_[id] == null);
  __atomic_store_n(&pending_[id], 0, __ATOMIC_RELEASE);
  __atomic_fetch_and(&tx_poll_mask_, ~(1u << id), __ATOMIC_RELEASE);
  active_[id] = uart;
  uart->set_interrupts_enabled(true);
}

void Rp2350UartEventSource::on_unregister_resource(
    Locker& locker, Resource* resource) {
  USE(locker);
  auto uart = static_cast<Rp2350UartEventResource*>(resource);
  int id = uart->uart_id();
  uart->set_interrupts_enabled(false);
  active_[id] = null;
  __atomic_store_n(&pending_[id], 0, __ATOMIC_RELEASE);
  __atomic_fetch_and(&tx_poll_mask_, ~(1u << id), __ATOMIC_RELEASE);
}

void Rp2350UartEventSource::notify_from_isr(int uart_id,
                                             uint32_t state_bits) {
  Rp2350UartEventSource* source = instance_;
  if (source == null || state_bits == 0) return;
  uint32_t previous = __atomic_fetch_or(
      &pending_[uart_id], state_bits, __ATOMIC_ACQ_REL);
  if (previous != 0) return;

  Rp2350EventDispatcher::instance()->wake_from_isr();
}

void Rp2350UartEventSource::request_tx_poll_from_isr(int uart_id) {
  __atomic_fetch_or(&tx_poll_mask_, 1u << uart_id, __ATOMIC_RELEASE);
  Rp2350EventDispatcher::instance()->wake_from_isr();
}

void Rp2350UartEventSource::request_tx_poll(int uart_id) {
  Rp2350UartEventSource* source = instance_;
  if (source == null) return;
  __atomic_fetch_or(&tx_poll_mask_, 1u << uart_id, __ATOMIC_RELEASE);

  // Wake without reporting completion before the physical FIFO is idle.
  Rp2350EventDispatcher::instance()->wake();
}

void Rp2350UartEventSource::cancel_tx_poll(int uart_id) {
  __atomic_fetch_and(&tx_poll_mask_, ~(1u << uart_id), __ATOMIC_RELEASE);
}

void Rp2350UartEventSource::uart0_interrupt() { interrupt(0); }
void Rp2350UartEventSource::uart1_interrupt() { interrupt(1); }

void Rp2350UartEventSource::interrupt(int uart_id) {
  Rp2350UartEventResource* resource = active_[uart_id];
  if (resource != null) resource->handle_interrupt_from_isr();
}

void Rp2350UartEventSource::dispatch_pending(const Locker& locker) {
  // Claim before inspecting hardware. A new transmission can request polling
  // while we check the old one; clearing afterward would lose that request.
  uint32_t poll_mask = __atomic_exchange_n(&tx_poll_mask_, 0, __ATOMIC_ACQ_REL);
  for (auto resource : resources()) {
    auto uart = static_cast<Rp2350UartEventResource*>(resource);
    int id = uart->uart_id();
    uint32_t state = __atomic_exchange_n(
        &pending_[id], 0, __ATOMIC_ACQ_REL);
    if ((poll_mask & (1u << id)) != 0) {
      if (uart->finish_transmit_if_idle()) {
        state |= kRp2350UartWriteState;
      } else {
        __atomic_fetch_or(&tx_poll_mask_, 1u << id, __ATOMIC_RELEASE);
      }
    }
    if (state != 0) dispatch(locker, resource, state);
  }
}

bool Rp2350UartEventSource::poll() {
  Locker locker(mutex());
  dispatch_pending(locker);
  return __atomic_load_n(&tx_poll_mask_, __ATOMIC_ACQUIRE) != 0;
}

}  // namespace toit

#endif  // TOIT_RP2350

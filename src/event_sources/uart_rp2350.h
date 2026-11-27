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

#pragma once

#include "../top.h"

#ifdef TOIT_RP2350

#include "event_rp2350.h"

namespace toit {

// The event bits intentionally match lib/uart.toit's ResourceState bits.
enum Rp2350UartState : uint32_t {
  kRp2350UartReadState = 1 << 0,
  kRp2350UartErrorState = 1 << 1,
  kRp2350UartWriteState = 1 << 2,
  kRp2350UartBreakState = 1 << 3,
};

class Rp2350UartEventResource : public Resource {
 public:
  Rp2350UartEventResource(ResourceGroup* group, int uart_id)
      : Resource(group), uart_id_(uart_id) {}

  int uart_id() const { return uart_id_; }

  // Called with this UART's NVIC interrupt disabled.
  virtual void set_interrupts_enabled(bool enabled) = 0;
  // Called from the UART ISR.
  virtual void handle_interrupt_from_isr() = 0;
  // Called by the event task while holding the EventSource mutex.
  virtual bool finish_transmit_if_idle() = 0;

 private:
  int uart_id_;
};

// Owns the two PL011 IRQs. ISRs only move bytes between the hardware FIFOs and
// resource rings, then set pending state and wake the shared event task.
class Rp2350UartEventSource : public Rp2350PeripheralEventSource {
 public:
  static Rp2350UartEventSource* instance() { return instance_; }

  Rp2350UartEventSource();
  ~Rp2350UartEventSource() override;

  static void notify_from_isr(int uart_id, uint32_t state_bits);
  static void request_tx_poll_from_isr(int uart_id);
  static void request_tx_poll(int uart_id);
  static void cancel_tx_poll(int uart_id);
  bool poll() override;

 protected:
  void on_register_resource(Locker& locker, Resource* resource) override;
  void on_unregister_resource(Locker& locker, Resource* resource) override;

 private:
  static void uart0_interrupt();
  static void uart1_interrupt();
  static void interrupt(int uart_id);

  void dispatch_pending(const Locker& locker);

  static Rp2350UartEventSource* instance_;
  static Rp2350UartEventResource* volatile active_[2];
  static uint32_t pending_[2];
  static uint32_t tx_poll_mask_;
};

}  // namespace toit

#endif  // TOIT_RP2350

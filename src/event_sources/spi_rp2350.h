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

namespace toit {

class EventSource;

// Callback boundary between the Toit SPI target resources and the RP2350
// transport. Callbacks may run in interrupt context when from_isr is true.
class Rp2350SpiTargetClient {
 public:
  virtual ~Rp2350SpiTargetClient() {}
  virtual void target_armed(bool from_isr) = 0;
  virtual void target_complete(uint32_t complete_bytes,
                               bool transfer_error,
                               bool from_isr) = 0;
};

// A transport owns its PL022 configuration, optional DMA channels, and CS edge
// handler. The Resource layer owns the GPIO/controller reservations and all
// buffers. `arm` must not retain any buffer after `abort` or `shutdown`
// returns.
class Rp2350SpiTargetTransport {
 public:
  virtual ~Rp2350SpiTargetTransport() {}
  virtual bool arm(uint8_t* transmit, uint8_t* receive,
                   uint32_t size, bool from_isr) = 0;
  virtual void abort() = 0;
  virtual void shutdown() = 0;
  virtual void handle_spi_interrupt_from_isr() = 0;
  virtual void handle_dma_interrupt_from_isr() = 0;
};

struct Rp2350SpiTargetTransportConfig {
  int controller;
  int mosi;
  int miso;
  int clock;
  int cs;
  uint8_t mode;
  bool transmit_lsb_first;
  bool receive_lsb_first;
  bool dma;
  // Ordinary Target completes upon reaching its mounted byte limit. A
  // BufferTarget stays mounted until CS rises, discarding excess clocks.
  bool complete_at_limit;
};

// Returns null when required DMA channels or memory are unavailable. The
// caller retains all GPIO reservations and buffers. This implementation uses
// the RP2350 PL022 block selected by `controller`.
Rp2350SpiTargetTransport* create_rp2350_spi_target_transport(
    const Rp2350SpiTargetTransportConfig& config,
    Rp2350SpiTargetClient* client);

// Creates the process-wide SPI controller event source. The platform VM owns
// the returned object and must add it before any SPI primitive is used.
EventSource* create_rp2350_spi_event_source();

}  // namespace toit

#endif  // TOIT_RP2350

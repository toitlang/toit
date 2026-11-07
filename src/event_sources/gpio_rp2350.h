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

// Base resource used by the event source to match an interrupt to its pin.
class Rp2350GpioEventResource : public Resource {
 public:
  Rp2350GpioEventResource(ResourceGroup* group, int pin)
      : Resource(group), pin_(pin) {}

  int pin() const { return pin_; }

 private:
  int pin_;
};

// Moves GPIO interrupts from the SDK callback into VM event dispatch on a
// shared peripheral task. The callback never takes a VM lock or touches a
// Resource, so a resource can be removed while an event is pending safely.
class Rp2350GpioEventSource : public Rp2350PeripheralEventSource {
 public:
  static Rp2350GpioEventSource* instance() { return instance_; }

  Rp2350GpioEventSource();
  ~Rp2350GpioEventSource() override;

  static uint32_t arm_timestamp();
  static uint32_t last_timestamp(int pin);
  bool poll() override;

 private:
  static void interrupt_callback(unsigned int gpio, uint32_t event_mask);

  static Rp2350GpioEventSource* instance_;
  static uint32_t sequence_;
  static uint32_t last_timestamps_[];
  static uint32_t pending_[2];
};

}  // namespace toit

#endif  // TOIT_RP2350

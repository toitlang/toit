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

#include "gpio_rp2350.h"

#include "hardware/gpio.h"
#include "hardware/irq.h"

namespace toit {

Rp2350GpioEventSource* Rp2350GpioEventSource::instance_ = null;
uint32_t Rp2350GpioEventSource::sequence_ = 0;
uint32_t Rp2350GpioEventSource::last_timestamps_[NUM_BANK0_GPIOS] = {};
uint32_t Rp2350GpioEventSource::pending_[2] = {};

Rp2350GpioEventSource::Rp2350GpioEventSource()
    : Rp2350PeripheralEventSource("RP2350 GPIO") {
  ASSERT(instance_ == null);
  instance_ = this;

  gpio_set_irq_callback(interrupt_callback);
  // The callback wakes a FreeRTOS semaphore, so keep the bank interrupt at a
  // FreeRTOS syscall-safe priority even if the SDK default is overridden.
  irq_set_priority(IO_IRQ_BANK0, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_enabled(IO_IRQ_BANK0, true);
  Rp2350EventDispatcher::instance()->attach(Rp2350EventDispatcher::GPIO, this);
}

Rp2350GpioEventSource::~Rp2350GpioEventSource() {
  irq_set_enabled(IO_IRQ_BANK0, false);
  for (int pin = 0; pin < static_cast<int>(NUM_BANK0_GPIOS); pin++) {
    gpio_set_irq_enabled(pin, GPIO_IRQ_LEVEL_LOW | GPIO_IRQ_LEVEL_HIGH, false);
  }
  gpio_set_irq_callback(null);
  instance_ = null;
  Rp2350EventDispatcher::instance()->detach(Rp2350EventDispatcher::GPIO, this);
  pending_[0] = pending_[1] = 0;
}

uint32_t Rp2350GpioEventSource::arm_timestamp() {
  return __atomic_load_n(&sequence_, __ATOMIC_ACQUIRE);
}

uint32_t Rp2350GpioEventSource::last_timestamp(int pin) {
  return __atomic_load_n(&last_timestamps_[pin], __ATOMIC_ACQUIRE);
}

void Rp2350GpioEventSource::interrupt_callback(unsigned int gpio,
                                               uint32_t event_mask) {
  Rp2350GpioEventSource* source = instance_;
  if (source == null || gpio >= NUM_BANK0_GPIOS) return;

  // A wait-for arms one level. Disable both levels before handing the event to
  // shared task so a level that remains asserted cannot flood interrupts.
  gpio_set_irq_enabled(gpio, GPIO_IRQ_LEVEL_LOW | GPIO_IRQ_LEVEL_HIGH, false);

  uint32_t timestamp =
      __atomic_add_fetch(&sequence_, 1, __ATOMIC_ACQ_REL);
  __atomic_store_n(&last_timestamps_[gpio], timestamp, __ATOMIC_RELEASE);

  // Concurrent waiters can rearm a pin before its earlier event is handled.
  // One pending dispatch is enough: all waiters share the ResourceState,
  // and last_timestamps_ retains the newest trigger sequence.
  uint32_t pending_bit = 1u << (gpio & 31);
  uint32_t* pending_word = &pending_[gpio >> 5];
  if (__atomic_fetch_or(pending_word, pending_bit, __ATOMIC_ACQ_REL) &
      pending_bit) {
    return;
  }

  Rp2350EventDispatcher::instance()->wake_from_isr();
  USE(event_mask);
}

bool Rp2350GpioEventSource::poll() {
  Locker locker(mutex());
  uint32_t pending[2];
  for (int i = 0; i < 2; i++) {
    pending[i] = __atomic_exchange_n(&pending_[i], 0, __ATOMIC_ACQ_REL);
  }
  // Clear before dispatch: a concurrent rearm/interrupt must remain pending
  // for the next pass. No Resource pointer ever crosses the ISR boundary.
  for (auto resource : resources()) {
    auto gpio = static_cast<Rp2350GpioEventResource*>(resource);
    int pin = gpio->pin();
    if (pending[pin >> 5] & (1u << (pin & 31))) {
      dispatch(locker, resource, last_timestamp(pin));
    }
  }
  return false;
}

}  // namespace toit

#endif  // TOIT_RP2350

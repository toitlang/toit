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

#include "stdio_rp2350.h"

#include <string.h>

#include "FreeRTOS.h"
#include "hardware/irq.h"
#include "pico/stdio.h"
#include "pico/stdio_usb.h"

#include "../utils.h"

#if !PICO_STDIO_USB_SUPPORT_CHARS_AVAILABLE_CALLBACK
#error "RP2350 stdin requires the Pico USB chars-available callback"
#endif

#ifndef PICO_STDIO_USB_LOW_PRIORITY_IRQ
#error "Set PICO_STDIO_USB_LOW_PRIORITY_IRQ to a dedicated user IRQ"
#endif

namespace toit {

static const word kStdinReadEvent = 1 << 0;

Rp2350StdinEventSource* Rp2350StdinEventSource::instance_ = null;
uint32_t Rp2350StdinEventSource::pending_ = 0;

Rp2350StdinEventSource::Rp2350StdinEventSource()
    : Rp2350PeripheralEventSource("RP2350 stdin") {
  ASSERT(instance_ == null);
  __atomic_store_n(&instance_, this, __ATOMIC_RELEASE);
  __atomic_store_n(&pending_, 0, __ATOMIC_RELEASE);

  // Pico invokes the chars-available callback from its USB worker IRQ. The
  // callback gives the dispatcher's FreeRTOS semaphore, so the IRQ must use a
  // FreeRTOS syscall-safe priority. A fixed user IRQ is required because the
  // SDK does not expose the dynamically claimed worker IRQ number.
  irq_set_priority(PICO_STDIO_USB_LOW_PRIORITY_IRQ,
                   configMAX_SYSCALL_INTERRUPT_PRIORITY);
  Rp2350EventDispatcher::instance()->attach(
      Rp2350EventDispatcher::STDIO, this);
  stdio_set_chars_available_callback(chars_available_callback, null);
  // Characters may have arrived before the callback was installed.
  request_poll();
}

Rp2350StdinEventSource::~Rp2350StdinEventSource() {
  // Stop future callbacks before detaching. An in-flight callback only
  // updates static state and wakes the dispatcher; it never dereferences this
  // source or any VM object.
  stdio_set_chars_available_callback(null, null);
  __atomic_store_n(&instance_, null, __ATOMIC_RELEASE);
  Rp2350EventDispatcher::instance()->detach(
      Rp2350EventDispatcher::STDIO, this);
  __atomic_store_n(&pending_, 0, __ATOMIC_RELEASE);
}

void Rp2350StdinEventSource::chars_available_callback(void* context) {
  USE(context);
  if (__atomic_load_n(&instance_, __ATOMIC_ACQUIRE) == null) return;
  uint32_t previous = __atomic_exchange_n(&pending_, 1, __ATOMIC_ACQ_REL);
  if (previous == 0) Rp2350EventDispatcher::instance()->wake_from_isr();
}

void Rp2350StdinEventSource::request_poll() {
  if (__atomic_load_n(&instance_, __ATOMIC_ACQUIRE) == null) return;
  uint32_t previous = __atomic_exchange_n(&pending_, 1, __ATOMIC_ACQ_REL);
  if (previous == 0) Rp2350EventDispatcher::instance()->wake();
}

void Rp2350StdinEventSource::on_register_resource(
    Locker& locker, Resource* resource) {
  if (size_ != 0) dispatch(locker, resource, kStdinReadEvent);
}

int Rp2350StdinEventSource::data_size() {
  Locker locker(mutex());
  return size_;
}

int Rp2350StdinEventSource::read(uint8* destination, int size) {
  int result;
  {
    Locker locker(mutex());
    result = Utils::min(size, size_);
    if (result == 0) return 0;
    memcpy(destination, buffer_, result);
    if (result < size_) {
      memmove(buffer_, buffer_ + result, size_ - result);
    }
    size_ -= result;
  }

  // The USB callback is edge-like. If the SDK still holds data because our
  // buffer was full, explicitly schedule another nonblocking drain now that
  // space is available.
  request_poll();
  return result;
}

bool Rp2350StdinEventSource::poll() {
  if (__atomic_exchange_n(&pending_, 0, __ATOMIC_ACQ_REL) == 0) return false;

  Locker locker(mutex());
  while (size_ < kBufferSize) {
    int value = getchar_timeout_us(0);
    if (value < 0) break;
    buffer_[size_++] = static_cast<uint8>(value);
  }
  if (size_ != 0) {
    for (auto resource : resources()) {
      dispatch(locker, resource, kStdinReadEvent);
    }
  }
  return false;
}

}  // namespace toit

#endif  // TOIT_RP2350

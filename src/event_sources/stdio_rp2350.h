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

class Rp2350StdinEventSource : public Rp2350PeripheralEventSource {
 public:
  static const int kBufferSize = 1024;

  static Rp2350StdinEventSource* instance() { return instance_; }

  Rp2350StdinEventSource();
  ~Rp2350StdinEventSource() override;

  int data_size();
  int read(uint8* destination, int size);
  bool poll() override;

 protected:
  void on_register_resource(Locker& locker, Resource* resource) override;

 private:
  static void chars_available_callback(void* context);
  static void request_poll();

  static Rp2350StdinEventSource* instance_;
  static uint32_t pending_;

  uint8 buffer_[kBufferSize];
  int size_ = 0;
};

}  // namespace toit

#endif  // TOIT_RP2350

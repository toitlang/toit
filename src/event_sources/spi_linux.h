// Copyright (C) 2024 Toitware ApS.
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

#if defined(TOIT_LINUX)

#include "./async_posix.h"
namespace toit {

class SpiEventSource : public AsyncEventSource {
 public:
  static SpiEventSource* instance() { return instance_; }

  SpiEventSource() : AsyncEventSource("SPI") {
    ASSERT(instance_ == null);
    instance_ = this;
  }

  ~SpiEventSource() override {
    instance_ = null;
  }

 protected:
  static SpiEventSource* instance_;
};

} // namespace toit

#endif // defined(TOIT_LINUX)

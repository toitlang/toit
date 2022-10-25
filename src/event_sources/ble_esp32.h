// Copyright (C) 2021 Toitware ApS.
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

#if defined(TOIT_FREERTOS) && CONFIG_BT_ENABLED

#include "../resource.h"
#include "ble.h"
namespace toit {

class BLEEventSource : public LazyEventSource {
 public:
  static BLEEventSource* instance() { return _instance; }

  BLEEventSource();

  void on_event(BLEResource* resource, word data);

 protected:
  bool start() override;

  void stop() override;

 protected:
  static BLEEventSource* _instance;

  ~BLEEventSource() override;
};

} // namespace toit

#endif // defined(TOIT_FREERTOS) && CONFIG_BT_ENABLED

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

#include "../top.h"

namespace toit {

enum {
  kBLEStarted = 1 << 0,
  kBLECompleted = 1 << 1,
  kBLEDiscovery = 1 << 2,
  kBLEConnected = 1 << 3,
  kBLEConnectFailed = 1 << 4,
  kBLEDisconnected = 1 << 5,
  kBLEServicesDiscovered = 1 << 6,
  kBLECharacteristicsDiscovered = 1 << 7,
  kBLEDescriptorsDiscovered = 1 << 8,
  kBLEValueDataReady = 1 << 9,
  kBLEValueDataReadFailed = 1 << 10,
  kBLEValueWriteSucceeded = 1 << 11,
  kBLEValueWriteFailed = 1 << 12,
  kBLEReadyToSendWithoutResponse = 1 << 13,
  kBLESubscriptionOperationSucceeded = 1 << 14,
  kBLESubscriptionOperationFailed = 1 << 15,
  kBLEAdvertiseStartSucceeded = 1 << 16,
  kBLEAdvertiseStartFailed = 1 << 17,
  kBLEServiceAddSucceeded = 1 << 18,
  kBLEServiceAddFailed = 1 << 19,
  kBLEDataReceived = 1 << 20,

};

}
// Copyright (C) 2022 Toitware ApS.
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
#include "../resource.h"
namespace toit {

enum {
  kBleStarted = 1 << 0,
  kBleCompleted = 1 << 1,
  kBleDiscovery = 1 << 2,
  kBleConnected = 1 << 3,
  kBleConnectFailed = 1 << 4,
  kBleDisconnected = 1 << 5,
  kBleServicesDiscovered = 1 << 6,
  kBleCharacteristicsDiscovered = 1 << 7,
  kBleDescriptorsDiscovered = 1 << 8,
  kBleValueDataReady = 1 << 9,
  kBleValueDataReadFailed = 1 << 10,
  kBleValueWriteSucceeded = 1 << 11,
  kBleValueWriteFailed = 1 << 12,
  kBleReadyToSendWithoutResponse = 1 << 13,
  kBleSubscriptionOperationSucceeded = 1 << 14,
  kBleSubscriptionOperationFailed = 1 << 15,
  kBleAdvertiseStartSucceeded = 1 << 16,
  kBleAdvertiseStartFailed = 1 << 17,
  kBleServiceAddSucceeded = 1 << 18,
  kBleServiceAddFailed = 1 << 19,
  kBleDataReceived = 1 << 20,
  kBleDiscoverOperationFailed = 1 << 21,
  kBleMallocFailed = 1 << 22
};

class BleResourceGroup;

class BleResource : public Resource {
 public:
  enum Kind {
    CENTRAL_MANAGER,
    PERIPHERAL_MANAGER,
    REMOTE_DEVICE,
    SERVICE,
    CHARACTERISTIC,
    DESCRIPTOR
  };
  BleResource(ResourceGroup* group, Kind kind)
      : Resource(group)
      , kind_(kind) {}

  Kind kind() const { return kind_; }

  BleResourceGroup* group() { return reinterpret_cast<BleResourceGroup*>(resource_group()); }

 private:
  const Kind kind_;
};

} // Namespace toit.

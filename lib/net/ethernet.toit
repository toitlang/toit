// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.ethernet show EthernetServiceClient
import system.services show ServiceProvider // For Toitdocs.
import esp32.net.ethernet show EthernetServiceProvider // For Toitdocs.

/**
Library to open an ethernet connection.

This library makes it possible to explicitly open a network connection,
  even if $net.open defaults to a different connection (like WiFi).

It requires a $ServiceProvider to be installed. On the ESP32, this
  could be the $EthernetServiceProvider.

# Example

```
import net.ethernet

main:
  network := ethernet.open
  // Use the network for network communication.
  ...
  network.close
```
*/

service_/EthernetServiceClient? := null
service-initialized_/bool := false

open --name/string?=null -> net.Client:
  if not service-initialized_:
    // We typically run the ethernet service in a non-system
    // container with --trigger=boot, so we need to give it
    // time to start so it can be discovered. We should really
    // generalize this handling for net.open and wifi.open too,
    // so we get a shared pattern for dealing with discovering
    // such network services at start up.
    service-initialized_ = true
    service_ = (EthernetServiceClient).open
        --timeout=(Duration --s=5)
        --if-absent=: null
  service := service_
  if not service: throw "ethernet unavailable"
  return net.Client service --name=name service.connect

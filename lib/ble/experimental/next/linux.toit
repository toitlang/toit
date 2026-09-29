// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The application API on a Linux Bluetooth adapter.

Linux has no BLE provider container; $open installs one in the calling
  process for the HCI adapter with the given index (hci0 is 0) and returns
  an $Adapter that uninstalls it on close. The process needs CAP_NET_ADMIN
  (for example `setcap cap_net_admin+ep` on the Toit runtime). Every time
  the provider takes the controller it first powers the adapter off in
  BlueZ, which hands it over exclusively; BlueZ powers it on again when the
  process lets go.
*/

import ..linux as linux
import ..linux-management as management
import ..native as native
import ..transport as transport
import ..service.gatt-provider as gatt
import .adapter
import .peripheral show Peripheral

/**
Opens adapter $index.

$peripheral-sessions is how many centrals a $Peripheral serves at once;
  while any is connected, the adapter does not connect to peripherals.
*/
open index/int --peripheral-sessions/int=1 -> Adapter:
  if not 1 <= peripheral-sessions <= 8: throw "INVALID_ARGUMENT"
  provider := Provider_ index peripheral-sessions
  provider.install
  adapter/Adapter? := null
  try:
    adapter = Adapter.with-cleanup_ --on-close=:: provider.uninstall
    return adapter
  finally:
    if not adapter: provider.uninstall

class Provider_ extends gatt.Provider:
  index_/int
  peripheral-sessions_/int

  constructor .index_ .peripheral-sessions_: super

  /**
  Takes the adapter from BlueZ and opens its user channel.

  Right after a user channel closes, the kernel removes and adds the
    adapter again and bluetoothd powers it on, so management requests and
    the open itself fail for a moment; they are retried for up to three
    seconds.
  */
  open-transport -> transport.Transport:
    deadline := Time.monotonic-us + 3_000_000
    while true:
      error := catch:
        power-off_
        return linux.LinuxTransport index_
      if Time.monotonic-us > deadline: throw error
      sleep --ms=50

  power-off_ -> none:
    client := management.Client (native.NativeTransport.management) index_
    try:
      if client.info.powered: client.set-powered false
    finally:
      client.close

  peripheral-session-limit -> int: return peripheral-sessions_

  // USB controllers can deliver the first ACL packet of a new link before
  // its Connection Complete event; wait for the event a little.
  early-acl-timeout -> Duration?: return Duration --ms=20

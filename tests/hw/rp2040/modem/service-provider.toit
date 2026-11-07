// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.service show Esp8285ServiceProvider
import log
import net
import system.storage
import uart

STATE ::= "toit-rp2040-test/network-containers"

class Provider extends Esp8285ServiceProvider:
  observations_/storage.Bucket
  constructor .observations_:
    super "toit-rp2040-test" "pico-bringup-test" --tx=0 --rx=1
        --dns-server=(net.IpAddress.parse "200.200.200.1")
        --logger=(log.default.with-level log.INFO-LEVEL)

  open-network -> net.Interface:
    network := super
    observations_["opens"] = (observations_.get "opens" --init=(: 0)) + 1
    return network

  close-network network/net.Interface:
    super network
    // The final client must release the UART even while this provider lives.
    (uart.Port --tx=0 --rx=1 --baud-rate=115_200).close
    observations_["closes"] = (observations_.get "closes" --init=(: 0)) + 1

main:
  state := storage.Bucket.open --ram STATE
  provider := Provider state
  provider.install
  state["ready"] = true

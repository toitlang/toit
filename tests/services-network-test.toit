// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io
import net
import net.tcp
import expect show *

import system.services show ServiceProvider ServiceSelector ServiceResource
import system.api.network show NetworkService NetworkServiceClient
import system.base.network show ProxyingNetworkServiceProvider

FAKE-TAG ::= "fake-$(random 1024)"
FAKE-SELECTOR ::= NetworkService.SELECTOR.restrict.allow --tag=FAKE-TAG

main:
  service := FakeNetworkServiceProvider
  service.install
  test-address service
  test-resolve service
  test-tcp service
  test-close service
  service.uninstall

  test-report

test-address service/FakeNetworkServiceProvider:
  local-address ::= net.open.address
  service.address = null
  expect-equals local-address open-fake.address
  service.address = local-address.to-byte-array
  expect-equals local-address open-fake.address
  service.address = #[1, 2, 3, 4]
  expect-equals "1.2.3.4" open-fake.address.stringify
  service.address = #[7, 8, 9, 10]
  expect-equals "7.8.9.10" open-fake.address.stringify
  service.address = null

test-resolve service/FakeNetworkServiceProvider:
  www-google ::= net.open.resolve "www.google.com"
  service.resolve = null
  expect-list-equals www-google (open-fake.resolve "www.google.com")
  service.resolve = www-google.map: it.to-byte-array
  expect-list-equals www-google (open-fake.resolve "www.google.com")
  service.resolve = []
  expect-equals [] (open-fake.resolve "www.google.com")
  service.resolve = [#[1, 2, 3, 4]]
  expect-equals [net.IpAddress #[1, 2, 3, 4]] (open-fake.resolve "www.google.com")
  service.resolve = [#[3, 4, 5, 6]]
  expect-equals [net.IpAddress #[3, 4, 5, 6]] (open-fake.resolve "www.google.com")
  service.resolve = null

test-tcp service/FakeNetworkServiceProvider:
  test-tcp-network open-fake
  service.enable-tcp-proxying
  test-tcp-network open-fake
  service.disable-tcp-proxying

test-tcp-network network/net.Interface:
  socket/tcp.Socket := network.tcp-connect "www.google.com" 80
  try:
    expect-equals 80 socket.peer-address.port
    expect-equals network.address socket.local-address.ip

    writer := socket.out
    writer.write "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
    reader := socket.in
    response := socket.in.read-all

    cr-index := response.index-of '\r'
    expect cr-index >= 0
    lf-index := response.index-of '\n'
    expect-equals cr-index + 1 lf-index

    actual := response[0..cr-index].to-string
    expected-200 := "HTTP/1.1 200 OK"
    expected-302 := "HTTP/1.1 302 Found"
    expect (actual == expected-200 or actual == expected-302)
        --message="Expected <$expected-200> or <$expected-302>, but was <$actual>"
  finally:
    socket.close
    network.close

test-close service/FakeNetworkServiceProvider:
  3.repeat:
    network := open-fake
    service.network.close
    yield
    expect network.is-closed
  3.repeat:
    network := open-fake
    service.disconnect
    yield
    expect network.is-closed

test-report:
  service := FakeNetworkServiceProvider
  service.install
  network := open-fake
  network.quarantine
  expect service.has-been-quarantined
  network.close

  // Check that we can quarantine a closed network.
  expect-not service.has-been-quarantined
  network.quarantine
  expect service.has-been-quarantined

  service.uninstall

// --------------------------------------------------------------------------

open-fake -> net.Client:
  service := (NetworkServiceClient FAKE-SELECTOR).open as NetworkServiceClient
  return net.open --service=service

class FakeNetworkServiceProvider extends ProxyingNetworkServiceProvider:
  proxy-mask_/int := 0
  address_/ByteArray? := null
  resolve_/List? := null
  network/net.Interface? := null
  quarantined_/bool := false

  constructor:
    super "system/network/test" --major=1 --minor=2  // Major and minor versions do not matter here.
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY-UNPREFERRED
        --tags=[FAKE-TAG]

  proxy-mask -> int:
    return proxy-mask_

  open-network -> net.Interface:
    expect-null network
    network = net.open --name="fake-net"
    return network

  close-network network/net.Interface -> none:
    expect-identical this.network network
    this.network = null
    network.close

  quarantine name/string -> none:
    expect-equals "fake-net" name
    quarantined_ = true

  update-proxy-mask_ mask/int add/bool:
    if add: proxy-mask_ |= mask
    else: proxy-mask_ &= ~mask

  has-been-quarantined -> bool:
    result := quarantined_
    quarantined_ = false
    return result

  address= value/ByteArray?:
    update-proxy-mask_ NetworkService.PROXY-ADDRESS (value != null)
    address_ = value

  resolve= value/List?:
    update-proxy-mask_ NetworkService.PROXY-RESOLVE (value != null)
    resolve_ = value

  enable-tcp-proxying -> none:
    update-proxy-mask_ NetworkService.PROXY-TCP true
  enable-udp-proxying -> none:
    update-proxy-mask_ NetworkService.PROXY-UDP true

  disable-tcp-proxying -> none:
    update-proxy-mask_ NetworkService.PROXY-TCP false
  disable-udp-proxying -> none:
    update-proxy-mask_ NetworkService.PROXY-UDP false

  address resource/ServiceResource -> ByteArray:
    return address_

  resolve resource/ServiceResource host/string -> List:
    return resolve_

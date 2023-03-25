// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.tcp
import writer
import expect show *

import system.services show ServiceProvider ServiceSelector ServiceResource
import system.api.network show NetworkService NetworkServiceClient
import system.base.network show ProxyingNetworkServiceProvider

FAKE_TAG ::= "fake-$(random 1024)"
FAKE_SELECTOR ::= NetworkService.SELECTOR.restrict.allow --tag=FAKE_TAG

main:
  service := FakeNetworkServiceProvider
  service.install
  test_address service
  test_resolve service
  test_tcp service
  test_close service
  service.uninstall

  test_report

test_address service/FakeNetworkServiceProvider:
  local_address ::= net.open.address
  service.address = null
  expect_equals local_address open_fake.address
  service.address = local_address.to_byte_array
  expect_equals local_address open_fake.address
  service.address = #[1, 2, 3, 4]
  expect_equals "1.2.3.4" open_fake.address.stringify
  service.address = #[7, 8, 9, 10]
  expect_equals "7.8.9.10" open_fake.address.stringify
  service.address = null

test_resolve service/FakeNetworkServiceProvider:
  www_google ::= net.open.resolve "www.google.com"
  service.resolve = null
  expect_list_equals www_google (open_fake.resolve "www.google.com")
  service.resolve = www_google.map: it.to_byte_array
  expect_list_equals www_google (open_fake.resolve "www.google.com")
  service.resolve = []
  expect_equals [] (open_fake.resolve "www.google.com")
  service.resolve = [#[1, 2, 3, 4]]
  expect_equals [net.IpAddress #[1, 2, 3, 4]] (open_fake.resolve "www.google.com")
  service.resolve = [#[3, 4, 5, 6]]
  expect_equals [net.IpAddress #[3, 4, 5, 6]] (open_fake.resolve "www.google.com")
  service.resolve = null

test_tcp service/FakeNetworkServiceProvider:
  test_tcp_network open_fake
  service.enable_tcp_proxying
  test_tcp_network open_fake
  service.disable_tcp_proxying

test_tcp_network network/net.Interface:
  socket/tcp.Socket := network.tcp_connect "www.google.com" 80
  try:
    expect_equals 80 socket.peer_address.port
    expect_equals network.address socket.local_address.ip

    writer := writer.Writer socket
    writer.write "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
    response := #[]
    while data := socket.read:
      response += data

    cr_index := response.index_of '\r'
    expect cr_index >= 0
    lf_index := response.index_of '\n'
    expect_equals cr_index + 1 lf_index

    actual := response[0..cr_index].to_string
    expected_200 := "HTTP/1.1 200 OK"
    expected_302 := "HTTP/1.1 302 Found"
    expect (actual == expected_200 or actual == expected_302)
        --message="Expected <$expected_200> or <$expected_302>, but was <$actual>"
  finally:
    socket.close
    network.close

test_close service/FakeNetworkServiceProvider:
  3.repeat:
    network := open_fake
    service.network.close
    yield
    expect network.is_closed
  3.repeat:
    network := open_fake
    service.disconnect
    yield
    expect network.is_closed

test_report:
  service := FakeNetworkServiceProvider
  service.install
  network := open_fake
  network.quarantine
  expect service.has_been_quarantined
  network.close
  service.uninstall

// --------------------------------------------------------------------------

open_fake -> net.Client:
  service := (NetworkServiceClient FAKE_SELECTOR).open as NetworkServiceClient
  return net.open --service=service

class FakeNetworkServiceProvider extends ProxyingNetworkServiceProvider:
  proxy_mask_/int := 0
  address_/ByteArray? := null
  resolve_/List? := null
  network/net.Interface? := null
  quarantined_/bool := false

  constructor:
    super "system/network/test" --major=1 --minor=2  // Major and minor versions do not matter here.
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY_UNPREFERRED
        --tags=[FAKE_TAG]

  proxy_mask -> int:
    return proxy_mask_

  open_network -> net.Interface:
    expect_null network
    network = net.open
    return network

  close_network network/net.Interface -> none:
    expect_identical this.network network
    this.network = null
    network.close

  quarantine id/string -> none:
    // TODO(kasper): Fix the id.
    expect_equals "wonk" id
    quarantined_ = true

  update_proxy_mask_ mask/int add/bool:
    if add: proxy_mask_ |= mask
    else: proxy_mask_ &= ~mask

  has_been_quarantined -> bool:
    result := quarantined_
    quarantined_ = false
    return result

  address= value/ByteArray?:
    update_proxy_mask_ NetworkService.PROXY_ADDRESS (value != null)
    address_ = value

  resolve= value/List?:
    update_proxy_mask_ NetworkService.PROXY_RESOLVE (value != null)
    resolve_ = value

  enable_tcp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_TCP true
  enable_udp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_UDP true

  disable_tcp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_TCP false
  disable_udp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_UDP false

  address resource/ServiceResource -> ByteArray:
    return address_

  resolve resource/ServiceResource host/string -> List:
    return resolve_
